package Genesis::Commands::Core;

use strict;
use warnings;

use Genesis;
use Genesis::Term;
use Genesis::UI;
use Genesis::Commands;
use JSON::PP qw/encode_json/;
use POSIX qw/strftime mktime/;

sub version {

	unless (scalar( @{[ keys(%{get_options()}), @_ ]} )) {
		output "Genesis v$Genesis::VERSION$Genesis::BUILD";
		exit 0;
	}

	# validate arguments
	my @valid_args = qw(
		semver is_dev major minor patch rc is_rc
		build_epoch build_code build_date commit is_dirty
	);
	if (@_) {
		my %check_args;
		@check_args{@valid_args} = (1) x scalar(@valid_args);
		my @bad_args = grep {! $check_args{$_}} @_;
		bail(
		)	if (@bad_args);
	}

	my %version;
	if ($Genesis::VERSION eq "(development)") {
		$version{semver} = "0.0.0-rc.0";
		$version{is_dev} = $JSON::PP::true;
	} else {
		$version{semver} = $Genesis::VERSION;
		$version{is_dev} = $JSON::PP::false;
	}

	my $tz = $ENV{ORIG_TZ};
	if (-l '/etc/localtime') {
		($tz = readlink '/etc/localtime') =~ s#.*zoneinfo/##;
	} elsif (-f '/etc/timezone') {
		$tz = `cat /etc/timezone`
	}

	$ENV{TZ} = $tz;
	POSIX::tzset();
	@version{qw[major minor patch rc]} = map {defined($_) ? $_+0 : $_} $version{semver} =~ m/^(\d+)\.(\d+)\.(\d+)(?:-rc(?:\.)?(\d+))?$/;
	$version{is_rc} = defined($version{rc}) ? $JSON::PP::true : $JSON::PP::false,
	my ($commit, $dirty, $Y, $M, $d, $h, $m, $s) = $Genesis::BUILD =~ m/\(([a-f0-9]+)(\+)?\) build (\d{4})(\d\d)(\d\d)\.(\d\d)(\d\d)(\d\d)$/;
	my $epoch = mktime($s||0,$m||0,$h||0, $d||1, ($M||1)-1, ($Y||1900)-1900,0,0,0) - mktime(0,0,0,1,0,70);
	@version{qw[build_epoch build_code build_date commit is_dirty]} = (
		$epoch,
		"$Y$M$d.$h$m$s",
		strftime("%Y-%b-%d %r %Z", localtime($epoch)),
		$commit,
		($dirty//'') eq '+' ? $JSON::PP::true : $JSON::PP::false,
	) if $Y;

	if (get_options->{json}) {
		%version = %version{@_} if @_;
		output encode_json(\%version);
	} else {
		output ($_ =~ /^is_/ ? ($version{$_} ? 'true' : 'false') : $version{$_})
			for (@_);
	}
	exit 0
}

sub ping {
	command_usage(1) if @_;
	print "PING!\n";
	exit 0
}

sub update {
	command_usage(1) if @_;

	require Service::Github;
	my $gh = Service::Github->new();

	my ($err,$label,@versions);
	if (get_options->{version}) {
		get_options->{version} =~ s/^v//;
		@versions = $gh->versions('genesis', version => get_options->{version});
		if (! @versions) {
			$err = csprintf("Genesis #C{v%s} does not exist", get_options->{version});
		} elsif (! $versions[0]->{url}) {
			$err = csprintf(
				"Genesis #C{v%s} found, but the executable is no longer available",
				get_options->{version}
			)
		} else {
			$label = csprintf("Version #C{v%s}",get_options->{version});
		}
	} else {
		@versions = grep {by_semver($_->{version}, $Genesis::VERSION) == 1} $gh->versions('genesis', include_prereleases => get_options->{pre});
		shift @versions while (@versions && ! defined($versions[0]->{url}));
		if (@versions) {
			$label = csprintf("A newer version (#C{v%s})", $versions[0]->{version});
		} elsif (get_options->{check}) {
			success({label => 'SUCCESS'},
				"\nYou are on the latest version of Genesis (currently #C{v%s}).\n",
				$Genesis::VERSION
			);
			exit 0
		} else {
			$err = csprintf(
				"No newer version of Genesis (currently #C{v%s}) is available",
				$Genesis::VERSION
			)
		}
	}

	if ($err) {
		if (get_options->{check}) {
			error "$err.\n";
			exit 1
		}
		bail "$err - cannot update.";
	}

	my $extra_versions = scalar(@versions)-1;
	my $summary = sprintf(
		"\n%s is available%s!\n\n",
		$label,
		($extra_versions > 0)
			? sprintf(" (with %d preceeding release%s)",$extra_versions, ($extra_versions > 2 ? 's' : ''))
			: ''
	);

	if (get_options->{details}) {
		for my $version (@versions) {
			my $c = ($version->{version} =~ /[\.-]rc[\.-]?(\d+)$/) ? "Y" : ($version->{prerelease} ? "y" : "G");
			my $d = "";
			if ($version->{date}) {
				$d = "Published ".$version->{date};
				$d .= " - \}#${c}i{Pre-release}#${c}\{" if $version->{prerelease};
				$d = " ($d)";
			}
			$summary .= sprintf("#%s{Release Notes for v%s%s}\n\n", $c, $version->{version}, $d);
			$summary .= render_markdown($version->{body});
		}
	}
	output $summary;
	exit 0 if get_options->{check};

	my $tmpdir = workdir();
	my $target = $ENV{GENESIS_CALLBACK_BIN};
	my $version = $versions[0]->{version};

	if (!get_options->{force}) {
		die_unless_controlling_terminal;
		my $overwrite = prompt_for_boolean(
			csprintf(
				"[AYour Genesis version is currently #C{v%s}, located at #M{%s}.\nDo you want to overwrite this file with #C{v%s}? [y|n]",
				$Genesis::VERSION, $target, $version
			),0);
		bail "Aborted!" unless $overwrite;
	}

	my (undef,undef,$file) = $gh->fetch_release('genesis',$version,$tmpdir);
	my (undef,undef,$fmode,undef,$fuid, $fgid) = stat($target);

	$fmode &= 0777; # Ignore setuid, setgid, sticky bits and file type

	if (-w $target && $fuid == $> && $fgid == $)) {
		copy_or_fail $file, $target;
		chmod_or_fail($fmode,$file);
	} else {
		mkfile_or_fail($tmpdir."/update_genesis", 0777, <<EOF);
#!/usr/bin/env bash
cp "$file" "$target"
chmod ${\(sprintf("%04o",$fmode))} "$target"
chown $fuid:$fgid "$target"
EOF
		my (undef,$rc) = run({stderr => '/dev/null'}, 'sudo','-n','true');
		warning( {label => "NOTICE"},
			"You will need to enter your password for sudo, as the Genesis ".
		  "executable is not in a location the current user has write-access to."
		) if ($rc);
		run({
			onfailure => "Could not overwrite existing Genesis with #C{v$version}",
			interactive =>1
		}, 'sudo', "$tmpdir/update_genesis");
	}

	# Clean up tempdir before exec-ing to another process (if safe)
	my @unexpected_contents = grep {
		$_ !~ /^(genesis|install_genesis)$/
	} lines(scalar(run('ls -1 "$1"',$tmpdir)));
	run('rm', '-rf', $tmpdir) unless scalar(@unexpected_contents);

	# Clean up before upgrading/downgrading
	delete(@ENV{'GENESIS_HOME','GENESIS_LIB','GENESIS_CALLBACK_BIN'});
	output "Verifying new version of Genesis...";
	exec {$target} $target, 'version';
}

sub hack {
	my ($cmd, @args) = @_;

	my ($top, $env);
	if (-d './.genesis/kits/') {
		require Genesis::Top;
		$top = Genesis::Top->new('.');
		if (-f $top->path($cmd =~ s/(.yml)?$/.yml/r)) {
			eval {$env = $top->load_env($cmd)};
			bail(
				"Attempted to load environment from #C{%s}, but encountered error: %s",
				$top->path($cmd.".yml"), $@
			) if $@;
			$cmd = shift @args;
		}
	}

	if ($cmd eq 'pry') {
		eval {require 'Pry.pm'};
		bail("Attempted to load Pry, but encountered error: %s", $@) if $@;
		Pry->pry;
		exit 0;
	}

	if ($cmd =~ /^\$top->/) {
		$cmd =~ s/^\$top->//;
		my $result = $top->$cmd(@args);
		Genesis::dump_var({level => 1}, result => $result);
	} elsif ($cmd =~ /^\$env->/) {
		$cmd =~ s/^\$env->//;
		my $result = $env->$cmd(@args);
		Genesis::dump_var({level => 1}, result => $result);
	} else {
		my ($module,$op,$cmd) = $cmd =~ /(.*)(::|->)([^:]*)$/;
		if ($module) {
			my $module_name = $module =~ s/::/\//gr;
			$module_name .= ".pm";
			require $module_name;
		}
		no strict 'refs';
		my $result = $op eq '::'
		 ? &{$module.'::'.$cmd}(@args)
		 : $module->$cmd(@args);
		Genesis::dump_var({level => 1}, result => $result);
	}
}

1;
# vim: fdm=marker:foldlevel=0:noet
