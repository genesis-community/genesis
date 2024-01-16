package Genesis::Hook;
use strict;
use warnings;

use Genesis qw/trace bug bail trace new_enough semver pushd popd/;
use Data::Dumper ();

sub init {
	my ($class, %ops) = @_;

	bug(
		"Missing environment argument for a perl-based kit hook call"
	) unless $ops{env};
	
	my $hook = bless({%ops, type => $ENV{GENESIS_KIT_HOOK}},$class);
	$hook->{features} = [$hook->env->features] 
		unless $ENV{GENESIS_KIT_HOOK} eq 'feature';

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

sub perform {
	$_[0]->kit->kit_bug(
		"Expect kit %s %s hook (perl module) to provide a 'perform' method",
		$_[0]->kit, $_[0]->type
	)
}

sub done {$_[0]->{complete} = 1}

sub check_minimum_genesis_version {
	my ($self,$min_version) = @_;
	bail(
		"The %s kit %s hook requires Genesis v%s or higher -- cannot continue.  ".
		"Please upgrade using #G{%s upgrade}",
		$self->kit->id,$ENV{GENESIS_KIT_HOOK}, $min_version, $ENV{GENESIS_CALL_BIN}
	) unless semver($Genesis::VERSION) && semver($min_version) && new_enough($Genesis::VERSION, $min_version);
}


sub env {$_[0]->{env}}
sub kit {$_[0]->env->kit}

sub deployed {defined($_[0]->exodus_lookup('data'))}

sub use_create_env {
	# TODO: integrate with ocfp feature env types, mayby?
	$ENV{GENESIS_USE_CREATE_ENV}||'false' eq 'true';
}

sub features {return @{$_[0]->{features}}}
sub want_feature {
	my ($self, $feature) = @_;
	unless (defined($self->{__wanted_features})) {
		$self->{__wanted_features} = {
			map {($_, 1)} ($self->features)
		}
	}
	return $self->{__wanted_features}{$feature};
}

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
		"Invalid Genesis Hook module: %s -- expected Genesis::Hook::<type>::<kit-name>",
		ref($self)
	) unless ref($self) =~ m/Genesis::Hook::(?:([^:]*)::)?([^:]*)$/;

	my $msg = $2;
	$msg .= " $1" if $1;
	my $v = __PACKAGE__->VERSION ? " #g{".(__PACKAGE__->VERSION)."}" : "";
	sprintf("[#M{%s}%s] ", $msg, $v);
}
1;
