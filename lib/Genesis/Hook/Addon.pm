package Genesis::Hook::Addon;
use strict;
use warnings;

use parent qw(Genesis::Hook);

use Genesis;

sub init {
	my ($class, %ops) = @_;
	my @missing = grep {!defined($ops{$_})} qw/env kit script args/;
	bug(
		"Missing required arguments for a perl-based kit hook call: %s",
		join(", ", @missing)
	) if @missing;
	
	my $obj = $class->SUPER::init(%ops);
	return $obj;
}

sub help {
	my ($self, %addons) = @_;

	if ($self->can('cmd_details')) {
		info (
			"\n#Gu{%s}\n[[  >>%s\n",
			$self->{label}, join("\n[[  >>", split("\n",$self->cmd_details()))
		);
		return 1;
	}

	# FIXME: The code below is not being called yes, so may contain errors:
	# - the passed in %addons does not seem compatible with the code below
	#   due to the includsion of $addons{$cmd} already containing the help
	#   output.

	# Loook for any extended addon hooks
	my @module_files = glob($self->kit->path("hooks/addon-*.pm"));
	foreach my $file (@module_files) {
		my $class = $self->load_hook_module($file, $self->kit);
		next unless $class && $class->can('cmd_details');
		my ($cmd) = $file =~ m{addon-(.*)\.pm};
		$addons{"$cmd"} = $class->cmd_details() // 'No help available';
	}

	unless (keys %addons) {
		info "No addons are defined for the %s kit.", $self->env->kit->id;
		return 0
	}

	my ($label, $short, $msg);
	info "The following addons are defined for the %s kit:", $self->env->kit->id;

	foreach my $cmd (sort keys %addons) {
		$label = $cmd =~ s/([^~]*).*/$1/r;
		$short = $cmd =~ s/([^~]*)(~(.*))?/$3/r;
		$short = "|$short" if $short;
		info(
			"\n  #Gu{%s%s}\n[[    >>%s",
			$label, $short, join("\n[[    >>", split("\n",$addons{$cmd}))
		);
	}
}

sub exodus_data {
	my $self = shift;
	return $self->{__exodus_data} ||= $self->env->exodus_lookup('.',{});
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
	my $data = read_json_from($self->bosh->execute(@args, '--json'));
	return $data->{Tables}[0]{Rows};
}

sub vault {
	my $self = shift;
	return $self->{vault} ||= $self->env->secrets_store->service;
}

sub results {
	return 1;
}
1;
