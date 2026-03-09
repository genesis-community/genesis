package Genesis::Hook;
use strict;
use warnings;

use Genesis qw/trace bug bail in_array new_enough semver pushd popd run humanize_path read_json_from save_to_yaml_file mkdir_or_fail/;
use Data::Dumper ();
use JSON::PP;
use Digest::SHA qw(sha1_hex);

sub init {
	my ($class, %opts) = @_;
	$class->check_for_required_args(\%opts, qw/env/);
	my $hook = bless({%opts, complete => 0, type => $ENV{GENESIS_KIT_HOOK}},$class);

	trace({raw => 1},
		"%senvironmental variables:\n%s",
		$hook->label,
		Data::Dumper->new([\%ENV])
			->Terse(1)
			->Pair('=')
			->Sortkeys(1)
			->Quotekeys(0)
			->Dump()
			=~ s/,\n/\n/gr    # remove trailing commas
			=~ s/\A\{\n//r    # remove leading brace line
			=~ s/\w*}\s*\z//r # remove trailing brace line
	);

	return $hook;
}

sub tempfile {
	my ($self, $file) = @_;
	$file //= 'tempfile-'.time().'-'.int(rand(10000));
	$file = $self->env->workpath($file);
	return $file;
}
sub tempdir {
	my ($self, $dir) = @_;
	$dir //= 'tempdir-'.time().'-'.int(rand(10000));
	$dir = $self->env->workpath($dir);
	mkdir_or_fail($dir) unless -d $dir;
	return $dir;
}

sub load_hook_module {
	my ($class, $file, $kit) = @_;

	$file = $kit->path($file) unless $file =~ m{^/};
	my $hook_module = $kit->get_hook_module($file);
	bail(
		"Hook module %s does not exist for kit %s",
		$file, $kit->id
	) unless $hook_module;

	# Check if module is already loaded to prevent redefinition warnings
	my $module_path = ($hook_module =~ s{::}{/}gr) .'.pm';

	if (!$INC{$module_path}) {
		eval {require $file};
		bail "Failed to load hook module %s: %s", $file, $@ if $@;
		# Mark it as loaded in %INC to prevent reloading
		$INC{$module_path} = $file;
	}
	return $hook_module;
}

sub perform {
	$_[0]->kit_bug(
		"Expect kit %s %s hook (perl module) to provide a 'perform' method",
		$_[0]->kit->id, $ENV{GENESIS_KIT_HOOK}
	)
}

sub done {
	my ($self) = shift;
	if (@_) {
		my $results = shift;
		$self->{results} = $results;
		$self->{complete} = defined($results) ? 1 : 0;
		return $results;
	} else {
		$self->{complete} = 1;
		$self->{results} = 1;
		return 1;
	}
}

sub results {$_[0]->completed ? $_[0]->{results} : undef}

sub completed {$_[0]->{complete}}

sub check_minimum_genesis_version {
	my ($self,$min_version) = @_;
	bail(
		"The %s kit %s hook requires Genesis v%s or higher -- cannot continue.  ".
		"Please upgrade using #G{%s upgrade}",
		$self->kit->id,$ENV{GENESIS_KIT_HOOK}, $min_version, $ENV{GENESIS_CALL_BIN}
	) unless semver($Genesis::VERSION) && semver($min_version) && new_enough($Genesis::VERSION, $min_version);
}


sub env {$_[0]->{env}}

sub deployed {
	($_[0]->env->deployments->current_state eq 'deployed') ? 1 : 0
}

sub use_create_env {
	return $_[0]->env && $_[0]->env->use_create_env;
}

sub features {
	my $self = shift;
	$self->{features} //= $self->env ? [$self->env->features] : [];
	return @{$self->{features}}
}

sub set_features {
	my $self = shift;
	delete($self->{__wanted_features});
	$self->{features} = [@_];
}

sub want_feature {
	my ($self, $feature) = @_;
	unless (defined($self->{__wanted_features})) {
		$self->{__wanted_features} = {
			map {($_, 1)} ($self->features)
		}
	}
	if(ref($feature) eq 'Regexp') {
		return scalar(
			grep {$_ =~ $feature}
			grep {$self->{__wanted_features}{$_}}
			keys $self->{__wanted_features}->%*
		) ? 1 : 0;
	} else {
		return $self->{__wanted_features}{$feature};
	}
}
sub wants_feature {$_[0]->want_feature($_[1])} # alias

# Special "universal" feature detection {{{
sub iaas {$_[0]->env && $_[0]->env->iaas}
sub scale {$_[0]->env && $_[0]->env->scale}
sub is_ocfp {$_[0]->env && $_[0]->env->is_ocfp}
sub cpi_name {$_[0]->env && $_[0]->env->cpi_name}
sub cpi_enabled {$_[0]->env && $_[0]->env->cpi_enabled}
# }}}

sub kit {$_[0]->env && $_[0]->env->kit}

sub kit_bug {
	my ($self, $msg, @args) = @_;
	bail(
		"Kit bug detected, but cannot determine kit for %s/%s",
		$self->env->name, $self->env->type
	) unless $self->kit;
	$self->kit->kit_bug($msg, @args);
}

sub kit_has_file {
	my ($self, $file) = @_;
	return -f $self->kit->path($file);
}

sub supports_iaas {
	my ($self) = @_;
	return in_array($self->iaas, $self->env->kit->metadata->{supports}->@*);
}

sub relative_env_path {
	my $self = shift;
	pushd($ENV{GENESIS_ORIGINATING_DIR});
	my $path = humanize_path($self->env->path($self->env->file));
	popd;
	$path
}

sub titleize {map { s/([\\w']+)/\\u\\L\$1/gr } @_}

sub label {
	my $self = shift;
	return $self->{label} if $self->{label};
	$self->kit->kit_bug(
		"Invalid Genesis Hook module: %s -- expected Genesis::Hook::<type>::<kit-name>[::<subcommand>]",
		ref($self)
	) unless ref($self) =~ m/Genesis::Hook::([^:]+)::([^:]+)(?:::([^:]+))?$/;

	my $msg = "$2 $1";
	$msg .= "/$3" if $3;
	my $v = __PACKAGE__->VERSION ? " #g{".(__PACKAGE__->VERSION)."}" : "";
	sprintf("[#M{%s}%s] ", $msg, $v);
}

sub spruce_merge {
	my ($self, @args) = @_;
	my $opts = ref($args[0]) eq 'HASH' ? shift @args : {};
	my @spruce_opts = ();
	my @files = ();
	my $idx = 1;
	while (my $arg = shift @args) {
		if (ref($arg) eq 'HASH') {
			# It is a raw hash, so convert it to json and store it in a file
			my $file = $self->tempfile("spruce-merge-$idx.yml");
			save_to_yaml_file($arg,$file);
		} elsif ($arg =~ m/^-/) {
			push @spruce_opts, $arg;
			if ($arg =~ m/^--(cherry-pick|prune)$/) {
				push @spruce_opts, shift @args;
			}
		} elsif (-f $arg) {
			# It is a file, so add it to the list of files
			push @files, $arg;
		} elsif (-f (my $file = $self->kit->path($arg))) {
			# It is a file in the kit, so add it to the list of files
			push @files, $file;
		} else {
			bug("Invalid argument for spruce merge: %s", $arg);
		}
	}

	my ($out, $rc, $err) = run($opts, 'spruce','merge', @spruce_opts, @files);
	return ($out, $rc, $err) if wantarray; # allows caller to handle errors
	bail "Failed to merge spruce files: %s", $err if $rc;
	return $out;
}

# JSON/YAML helpers {{{
sub TRUE  {JSON::PP::true}
sub FALSE {JSON::PP::false}
sub NULL  {JSON::PP::null}
# }}}

sub check_for_required_args {
	my ($class, $ops, @required) = @_;
	my @missing = grep {!defined($ops->{$_})} @required;
	bug(
		"Missing required arguments for a perl-based kit hook call: %s",
		join(", ", @missing)
	) if @missing;
	return 1;
}

sub require_hook_lib {
	my ($caller_package, $filename, $line) = caller();
	use File::Basename qw(dirname);
	use Cwd qw(abs_path);
	eval "use lib dirname(abs_path(\$filename)).'/lib';";
}

sub get_config_override {
	my ($self, $key, $default) = @_;
	my $base = 'bosh-configs';
	if ($key =~ m/^(cloud|runtime|cpi)\.(.+)$/) {
		# If the key starts with cloud, runtime, or cpi, its good as-is
	} elsif ($self->isa('Genesis::Hook::CloudConfig')) {
		$base .= '.cloud';
	} elsif ($self->isa('Genesis::Hook::RuntimeConfig')) {
		$base .= '.runtime';
	} elsif ($self->isa('Genesis::Hook::CpiConfig')) {
		$base .= '.cpi';
	} else {
		require mro;
		my @parents = mro::get_linear_isa(ref($self));
		my $parent_class = $parents[1] if @parents > 1;
		bail(
			"%s hooks must specify the bosh_config type as the first part of the lookup key",
			$parent_class // ref($self)
		);
	}
	my $value = $self->env->lookup("$base.$key", $default);
	return $value;
}

sub exodus_data {
	my $self = shift;
	$self->{__exodus_data} ||= $self->env->exodus_lookup('.',{});
	return $self->{__exodus_data} unless @_;
	return $self->{__exodus_data}{$_[0]} if @_ == 1;
	my @results = map {$self->{__exodus_data}{$_}} @_;
	return wantarray ? @results : \@results;
}

sub bosh {
	my $self = shift;
	return $self->{__bosh} ||= sub {
		my $bosh = $_[0]->env->bosh;
		$bosh->connect_and_validate();
		$bosh;
	}->($self);
}

sub read_json_from_bosh {
	my ($self, @args) = @_;
	my ($data,$rc,$err) = read_json_from($self->bosh->execute(@args, '--json'));
	bail(
		"Failed to read JSON from BOSH command: %s", $err
	) if $rc;
	return $data->{Tables}[0]{Rows};
}
sub get_credhub_variable {
	my ($self, $prefix, $path, $key, $value) = @_;
	my $secret_sha = substr(sha1_hex("$path--$key--".$value),0,8);
	my $cred_name = "$prefix$path--$key--$secret_sha";
	return $cred_name;
}

1;
# vim: fdm=marker:ts=2:sw=2:sts=2:noet:cc=80
