package Genesis::Hook::Addon;
use strict;
use warnings;

use parent qw(Genesis::Hook);

use Genesis;

sub init {
	my ($class, %opts) = @_;
	$class->check_for_required_args(\%opts, qw/env kit script args/);
	my $obj = $class->SUPER::init(%opts);

	# Deal with help option if present
	if ($opts{help}) {
		$obj->help;
		exit 0;
	}

	return $obj;
}

sub help {
	my ($self, %addons) = @_;

	if ($self->can('cmd_details')) {
		my $cmd_details = $self->cmd_details();
		if (ref $cmd_details eq 'HASH') {
			$self->kit_bug(
				"This kit has incorrectly defined multiple commands in %s - hooks/addon.pm ".
				"is the only addon that can define multiple commands.",
				$self->{file} =~ s{^.*(hooks/addon\.pm)$}{$1}r
			) unless $self->{file} =~ /hooks\/addon\.pm$/;
			$addons{$_} = $cmd_details->{$_} for keys %$cmd_details;
		} else {
			info (
				"\n#Gu{%s}\n[[  >>%s\n",
				$self->{label}, join("\n[[  >>", split("\n",$self->cmd_details()))
			);
			return 1;
		}
	}

	# Loook for any extended addon hooks
	my @module_files =
		map {substr($_,length($self->kit->path())+1)}
		grep { /\/addon-[^.]*(.pm)?$/ } # ignore disabled or other invalidly named files
		glob($self->kit->path("hooks/addon-*"));

	foreach my $file (@module_files) {
		my $cmd = $file =~ s{^.*hooks/addon-(.*?)(\.pm)?$}{$1}r;
		if ($file !~ /\.pm$/) {
			next if in_array($file.'.pm', @module_files); # prefer perl modules over other files
			# run the help command on the bash script
			my ($out, $rc, $err) = run({
				interactive => 0, stderr => undef
			},
			'cd "$1"; source .helper; hook=$2; shift 2; $hook "$@"',
			$self->kit->path, $file, 'help'
			);
			trace("Failed to run addon help command for %s (rc: %s): %s", $file, $rc, $err) if $rc;;
			$addons{$cmd} = $out unless $rc;
		} else {
			eval {
				my $class = $self->load_hook_module($file, $self->kit);
				next unless $class && $class->can('cmd_details');
				my ($cmd) = $file =~ m{addon-(.*)\.pm};
				# FIXME: Initializing the subcommand addons with the current env is a hack,
				# 			but it is needed to ensure that the addon's cmd_details method
				# 			can access the environment variables and other context.
				local $ENV{GENESIS_ADDON_SCRIPT} = $cmd;
				$addons{"$cmd"} = $class->cmd_details() // 'No help available';
			};
			trace("Failed to load addon module %s: %s", $file, $@) if $@;
		}
	}

	unless (keys %addons) {
		info(
			"No addons are defined for the %s kit.",
			$self->env->kit->id
		);
		return 0
	}

	my ($label, $short, $msg);
	info "\nThe following addons are defined for the #C{%s} kit:", $self->env->kit->id;

	foreach my $cmd (sort keys %addons) {
		$label = $cmd =~ s/~/\|/r;
		info(
			"\n  #Gu{%s}\n[[    >>%s",
			$label, join("\n[[    >>", split("\n",$addons{$cmd}))
		);
	}
	print STDERR "\n";
	return $self->done(1);
}

use Getopt::Long qw(GetOptionsFromArray);
sub parse_options {
	my ($self, $opt_defn, %opts) = @_;
	Getopt::Long::Configure(
		qw(no_ignore_case bundling no_pass_through auto_abbrev permute)
	);
	GetOptionsFromArray($self->{args}, \%opts, @$opt_defn)
		or bail("Error parsing command line arguments");
	my $bad_opts = join(", ", grep {/^-/} @{$self->{args}});
	bail("Unknown option(s) passed to %s: %s", $self->label, $bad_opts) if $bad_opts;
	return wantarray ? %opts : \%opts;
}


sub vault {
	my $self = shift;
	return $self->{vault} ||= $self->env->secrets_store->service;
}

sub results {
	return 1;
}
1;
