package Genesis::Secret;
use strict;
use warnings;
use Genesis;
use Genesis::State qw/envset/;
use Genesis::Term qw/checkbox/;

sub new { 
	my ($class,$path,%opts) = @_;
	bug 'Cannot directly instantiate a Genesis::Secret - use build to instantiate a derived class'
		if $class eq __PACKAGE__;

	my %src = 
		defined($opts{_ch_name}) ? (source => 'manifest', var_name => delete($opts{_ch_name})) :
		defined($opts{_feature}) ? (source => 'kit',      feature  => delete($opts{_feature})) :
		();
	my ($args,$errors,$alt_path) = $class->validate_definition($path,%opts);
	if ($errors && ref($errors) eq 'ARRAY' and @{$errors}) {
		$args->{_ch_name} = $src{var_name} if ($src{source}//'') eq 'manifest';
		$args->{_feature} = $src{feature}  if ($src{source}//'') eq 'kit';
		return $class->reject(
			$class->type(), "Errors in definition:".join("\n- ", '', @{$errors}),
			$path, $args, 
		);
	} else {
		my %src = 
		return bless({
			path => $alt_path || $path,
			definition => $args,
			%src
		}, $class);
	}
}

sub build {
	my ($class,$type,$source,$path,%definition) = @_;
	# FIXME: resolve multiple
	explain("called $type -> $path");
	bug ('Cannot call build on %s -- use build on %s', $class, __PACKAGE__)
		if $class ne __PACKAGE__;

	my $package = class_of($type);
	my $loaded = eval "require $package";
	return $class->reject(
		$type, "No secret definition found for type $type - cannot parse.",
		$path, {%definition}
	) unless $loaded;


	my $secret = eval "$package->new(\$path,\%definition);";
	my $err = $@;
	return $class->reject(
		$type, "$err", $path, {%definition}
	) if $err;
	return $secret;
}

sub save {
	my ($self) = @_;
	$self->plan->store->write($self);
}

sub load {
	my ($self,$value) = @_;
	$self->plan->store->read($self);
}

sub reject {
	my ($class_or_ref,$subject,$error,$path,$args) = @_;
	if ($class_or_ref->isa(__PACKAGE__)) {
		$path //= $class_or_ref->path;
		$args //= $class_or_ref->definition;
		$args->{_feature} //= $class_or_ref->{feature}  if $class_or_ref->from_kit;
		$args->{_ch_name} //= $class_or_ref->{var_name} if $class_or_ref->from_manifest;
	}
	trace("reporting secret error $subject: $error -> $path");
	require Genesis::Secret::Invalid;
	return Genesis::Secret::Invalid->new($path, data => $args, subject => $subject, error => $error);
}

sub validate_definition {
	my ($class, $path, %opts) =  @_;
	
	unless ($ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION}) {
		return $class->_validate_constructor_opts($path, %opts) if $class->can('_validate_constructor_opts');

		my @errors;
		my @required_options = $class->_required_constructor_opts;
		my @valid_options = (@required_options, $class->_optional_constructor_opts);
		push(@errors, "Missing required '$_' argument") for grep {!$opts{$_}} @required_options;
		push(@errors, "Unknown '$_' argument specified") for grep {my $k = $_; ! grep {$_ eq $k} @valid_options} keys(%opts);
		return (
			\%opts,
			\@errors, 
			$path,
		) if @errors; 
	}
	return (\%opts, $path);
}

sub _required_constructor_opts {
	bug('%s did not define _required_contructor_opts', $_[0])
}

sub _optional_constructor_opts {
	bug('%s did not define _optional_constructor_opts', $_[0])
}

sub path          {$_[0]->{path}}
sub all_paths     {($_[0]->path)}
sub full_path     {$_[0]->base_path.$_[0]->path}
sub default_key   {undef}
sub definition    {$_[0]->{definition}}
sub value         {$_[0]->{value}||$_[0]->{stored_value}}
sub has_value     {defined($_[0]->{stored_value})}
sub missing       {!$_[0]->has_value} 
sub set_plan      {$_[0]->{plan} = $_[1]; $_[0]}
sub plan          {$_[0]->{plan} || bail('Secret not in a plan -- cannot continue')}
sub base_path     {$_[0]->plan->store->base}

sub source        {$_[0]->{source}//''}
sub from_kit      {$_[0]->source eq 'kit'}
sub feature       {$_[0]->{feature}}
sub from_manifest {$_[0]->source eq 'manifest'}
sub var_name      {$_[0]->{var_name}}

sub credhub       {$_[0]->plan->credhub};

sub type {
	my $ref = shift;
	my $type = ref($ref) || $ref; # Handle class or object
	$type =~ s/.*:://;
	({
		# Put exceptions here
	})->{$type} || lc($type);
}

sub label {ucfirst($_[0]->type)}

# Helper Function -- call with ::, not ->
sub class_of {
	my $type = shift;
	__PACKAGE__."::".(({
		dhparams => 'DHParams',
		ssh => 'SSH',
		rsa => 'RSA',# Put exceptions here
	})->{$type} || ucfirst($type));
}

# valid - return true if the secret definition is valid
sub valid {
	return 1; # Default is always valid - override in derived class
}

sub check_value {
	my $self = shift;
	my @missing_keys;
	if ($self->_required_value_keys) {
		return ('missing') unless  ref($self->value) eq 'HASH';
		push(@missing_keys, $_) for (grep {!defined($self->value->{$_})} $self->_required_value_keys);
		if (@missing_keys) {
			return ('missing', join("\n",
				map {sprintf("%smissing key ':%s'", checkbox(0), $_)} @missing_keys
			));
		}
	} elsif (!defined($self->value)) {
		return ('missing');
	}
	return 'ok';
}

sub validate_value {
	my ($self) = @_;
	my ($check, $check_msg) = $self->check_value();
	return ($check, $check_msg) unless $check eq 'ok' && $self->can('_validate_value');
	my ($results, @validations) = $self->_validate_value();
	my $show_all_messages = ! envset("GENESIS_HIDE_PROBLEMATIC_SECRETS");
	my %priority = ('error' => 0, 'warn' => 1, 'ok' => 2);
	my @results_levels = 
		sort {$priority{$a}<=>$priority{$b}}
		uniq('ok',
			map {$_ ? ($_ =~ /^(error|warn)$/ ? $_ : 'ok') : 'error'}
			map {$_->[0]}
			values %$results
		);
	return (
		$results_levels[0], join("\n",
			map {checkbox($_->[0]).$_->[1]}
			grep {$show_all_messages || $priority{$_->[0]} <= $priority{$results_levels[0]}}
			map {$results->{$_}}
			grep {exists $results->{$_}}
			@validations
		)
	);
}

sub get_safe_command_for {
	my ($self, $action, %opts) = @_;
	my $action_command = "_get_safe_command_for_$action";
	return $self->$action_command(%opts) if $self->can($action_command);

	if ($action eq 'remove') {
		return ('rm', '-f', $self->full_path);
	} else {
		bug(
			"Class %s does not provide command to %s secrets from safe/vault",
			ref($self),
			$action
		)
	}
}

sub process_command_output {
	my ($self, $action, $out, $rc, $err) = @_;
	$out =~ s/^\s*// if $out;
	return ($out, $rc, $err);
}

sub import_from_credhub {
	my ($self) = @_;

	# Check that the secret definition is from manifest
	return ('error', "credhub import path unknown for secret")
		unless $self->from_manifest && $self->var_name;

	my ($value, $err) = $self->credhub->get($self->var_name);
	return ('error', $err) if $err;

	return $self->_import_from_credhub($value); 
}

# _import_from_credhub - catch-all for secrets that don't implement _import_from_credhub
sub _import_from_credhub {
	my $self = shift;
	return (
		'error', 
		sprintf("Cannot import %s secrets from CredHub - not implemented", $self->type)
	)
}

sub is_command_interactive {
	return 0
}

### Instance Methods {{{
# describe - english description of secret {{{
sub describe {

	my ($self, $alternative) = @_;
	return $self->label . " secret" unless $self->can('_description'); # default, override in derived class

	my ($label,@features) = $self->_description($alternative);
	return wantarray
		? ($self->{path}, $label, join (", ", grep {$_} @features))
		: (@features ? sprintf('%s - %s', $label, join (", ", grep {$_} @features)) : $label);
}

sub get {
	my ($self, $property, $default) = @_;
	# Do we need to bug() on invalid property?
	return $self->{definition}{$property}//$default
}

sub has {
	my ($self, $property) = @_;
	return exists($self->{definition}{$property});
}

sub set {
	my ($self, $property, $value) = @_;
	my $new_props = {%{$self->{definition}}, $property => $value};
	# FIXME:  Ideally we should make sure that altering the definition results in
	# a valid definition, but a valid from-source definition is different from a
	# valid processed definition (ie self_signed can't be in kit definition, but
	# is required in a processed definition.
	#
	# For now, assume code will produce valid processed definition;
	#
	#my ($args,$errors,$alt_path) = ref($self)->validate_definition($self->path,%$new_props);
	#bail(
	#	"Error in updating %s %s secret definition: %s",
	#	($self->describe)[0..1], join("\n- ", '', @{$errors})
	#) if @{$errors||[]};
	return $self->{definition}{$property} = $value;
}

sub set_value {
	my ($self, $value, %opts) = @_;
	$self->_set_value($value);
	$self->{stored_value} = delete($self->{value}) if ($opts{in_sync});
}

# Override in derived classes for special value handling
sub _set_value {
	$_[0]->{value} = $_[1]
}

sub promote_value_to_stored {
	my $self = shift;
	$self->{stored_value} = delete($self->{value});
}

sub _required_value_keys {undef}
1;
# vim: fdm=marker:foldlevel=1:noet
