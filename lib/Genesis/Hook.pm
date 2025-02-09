package Genesis::Hook;
use strict;
use warnings;

use Genesis qw/trace bug bail trace new_enough semver pushd popd run humanize_path/;
use Data::Dumper ();
use JSON::PP;

sub init {
	my ($class, %ops) = @_;
	$class->check_for_required_args(\%ops, qw/env/);
	my $hook = bless({%ops, complete => 0, type => $ENV{GENESIS_KIT_HOOK}},$class);

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

sub load_hook_module {
	my ($class, $file, $kit) = @_;

	my $hook_module;

	if (-f $file) {
		open my $fh, '<', $file;
		my $line = <$fh>;
		$line = <$fh> while ($line =~/^\s*(#.*)?$/);
		close $fh;

		if ($line =~ /^package (Genesis::Hook::[^ ]*)/) {
			$hook_module = $1;
		}
	} else {
		bail(
			"Hook module %s does not exist for kit %s",
			$file, $kit->id
		);
	}

	eval {require $file};
	bail "Failed to load hook module %s: %s", $file, $@ if $@;

	return $hook_module;
}

sub perform {
	$_[0]->kit->kit_bug(
		"Expect kit %s %s hook (perl module) to provide a 'perform' method",
		$_[0]->kit, $_[0]->type
	)
}

sub done {
	my ($self) = shift;
	if (@_) {
		my $results = shift;
		$self->{results} = $results;
		$self->{complete} = defined($results) ? 1 : 0;
	} else {
		$self->{complete} = 1;
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
sub kit {$_[0]->env && $_[0]->env->kit}

sub deployed {defined($_[0]->exodus_lookup('data'))}

sub use_create_env {
	# TODO: integrate with ocfp feature env types, mayby?
	$ENV{GENESIS_USE_CREATE_ENV}||'false' eq 'true';
}

sub features {
	my $self = shift;
	$self->{features} //= $self->env ? [$self->env->features] : [];
	return @{$self->{features}}
}

sub want_feature {
	my ($self, $feature) = @_;
	unless (defined($self->{__wanted_features})) {
		$self->{__wanted_features} = {
			map {($_, 1)} ($self->features)
		}
	}
	return $self->{__wanted_features}{$feature};
}
sub wants_feature {$_[0]->want_feature($_[1])} # alias

# Special "universal" feature detection {{{
sub iaas {$_[0]->env && $_[0]->env->iaas}
sub scale {$_[0]->env && $_[0]->env->scale}
sub is_ocfp {$_[0]->env && $_[0]->env->is_ocfp}
# }}}

sub set_features {
	my $self = shift;
	delete($self->{__wanted_features});
	$self->{features} = [@_];
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
	# TODO: make this support passing in json/yaml directly
	my ($out, $err, $res) = run($opts, 'spruce','merge', @args);
	bail "Failed to merge spruce files: %s", $err if $res;
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

1;
# vim: fdm=marker:ts=2:sw=2:sts=2:noet:cc=80
