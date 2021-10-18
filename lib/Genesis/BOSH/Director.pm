package Genesis::BOSH::Director;

use strict;
use warnings;
use utf8;

use base 'Genesis::BOSH';
use Genesis;
use Genesis::Vault;

### Class Methods {{{

# new - raw instantiation of a BOSH director object {{{
sub new {

	my ($class, $alias, %opts) = @_;

	my ($schema,$host,$port) = $opts{url} =~ qr(^(http(?:s?))://(.*?)(?::([0-9]*))?$);

	my $director = {
		schema => $schema,
		host => $host,
		port => $port || 25555,
		url => $opts{url},
		ca_cert => $opts{ca_cert},
		client => $opts{client},
		secret => $opts{secret},
		alias  => $alias,
		deployment => $opts{deployment},
		use_local_config => $opts{use_local_config},
		validated => ($ENV{GENESIS_BOSH_VERIFIED}||"") eq $alias
	};

	return bless($director, $class);
}

# }}}
# from_exodus - create a new BOSH director object based on exodus data {{{
sub from_exodus {
	my ($class, $alias, %opts) = @_;
	my ($exodus, $exodus_source);
	if ($opts{exodus_data}) {
		$exodus = $opts{exodus_data};
		$exodus_source = 'provided';
	} else {
		$opts{vault} ||= (Genesis::Vault->current || Genesis::Vault->default);
		if (!$opts{exodus_path}) {
			$opts{exodus_path} =
				($opts{exodus_mount} || '/secret/exodus/').
				$alias.'/'.
				($opts{bosh_deployment_type} || 'bosh');
		}
		$opts{vault}->connect_and_validate();
		trace("Trying to fetch BOSH director exodus data for '$opts{exodus_path}'");
		$exodus = $opts{vault}->get($opts{exodus_path});
		$exodus_source = sprintf("under #C{%s} on vault #M{%s}", $opts{exodus_path}, $opts{vault}->name);
		unless ($exodus) {
			trace("#R{[ERROR]} No exodus data found %s", $exodus_source);
			return;
		}
	}

	# validate exodus data
	my @missing_keys;
	for (qw(url admin_username admin_password ca_cert kit_name)) {
		push(@missing_keys,$_) unless $exodus->{$_};
	}
	if (@missing_keys) {
		trace(
			"#R{[ERROR]} Exodus data %s does not appear to be for a BOSH deployment:\n".
			"        Missing keys: %s",
			$exodus_source, join(", ", @missing_keys)
		);
		return;
	}
	if ($exodus->{kit_name} ne 'bosh' && ! $exodus->{is_bosh}) {
		trace(
			"#R{[ERROR]} Exodus data %s does not appear to be for a BOSH deployment:\n".
			"        Kit type is #M{%s}",
			$exodus_source, $exodus->{kit_name}
		);
		return;
	}

	return $class->new($alias,
		url     => $exodus->{url},
		client  => $exodus->{admin_username},
		secret  => $exodus->{admin_password},
		ca_cert => $exodus->{ca_cert},
		deployment => $opts{deployment}
	);
}

# }}}
# from_alias - create a BOSH director object that uses a local config alias {{{
sub from_alias {
	my ($class, $alias, %opts) = @_;

	my $config_home = $opts{config_home} || "$ENV{HOME}/.bosh/config";
	return undef unless -f $config_home;
	my $bosh = load_yaml_file($config_home)
		or return;

	for my $e (@{ $bosh->{environments} || []  }) {
		return $class->new(
			$alias,
			url => $e->{url},
			ca_cert => $e->{ca_cert},
			use_local_config => 1,
			deployment => $opts{deployment}
		) if $e->{alias} eq $alias;
	}

	return;
}

# }}}
# from_environment - create a BOSH director object from current environment variables {{{
sub from_environment {
	my $class = shift;

	if (is_valid_uri($ENV{BOSH_ENVIRONMENT}) && $ENV{BOSH_CLIENT}) {
		return $class->new(
			$ENV{BOSH_ALIAS},
			url => $ENV{BOSH_ENVIRONMENT},
			client => $ENV{BOSH_CLIENT},
			secret => $ENV{BOSH_CLIENT_SECRET},
			ca_cert => $ENV{BOSH_CA_CERT},
			deployment => $ENV{BOSH_DEPLOYMENT}
		);
	} else {
		return $class->from_alias($ENV{BOSH_ALIAS} || $ENV{BOSH_ENVIRONMENT}, deployment => $ENV{BOSH_DEPLOYMENT});
	}
}

# }}}
# exodus_path - return the exodus path from which the connection details will be read {{{
sub exodus_path {
	my ($class, $alias, %opts) = @_;
	return $opts{exodus_path} || (
		($opts{exodus_mount} || '/secret/exodus/').
		$alias.'/'.
		($opts{bosh_deployment_type} || 'bosh')
	);
}
# }}}
# }}}

## Instance Methods {{{

# deployment - set or get target deployment {{{
sub deployment {
	my $self = shift;
	$self->{deployment} = shift if @_;
	bug("Too many arguments to Genesis::BOSH::Director#deployment: expecting at most 1, got extra: ".join(', ',@_))
	  if @_;
	return $self->{deployment};
}

# }}}
# environment_variables - retrieve BOSH environment variables for this BOSH director {{{
sub environment_variables {
	my ($self) = @_;
	my %envs = (
		BOSH_ALIAS         => $self->{alias},
		BOSH_ENVIRONMENT   => $self->{schema}."://".$self->{host}.":".$self->{port},
		BOSH_CA_CERT       => $self->{ca_cert},
		BOSH_CLIENT        => $self->{client},
		BOSH_CLIENT_SECRET => $self->{secret},
	);
	$envs{BOSH_DEPLOYMENT} = $self->{deployment} if $self->{deployment};
	return %envs;
}

# }}}
# connect_and_validate - connect to the BOSH director and validate access {{{
sub connect_and_validate {
	my ($self) = @_;
	return $self if $self->{validated};
	debug "Checking BOSH at '$self->{alias}' for connectivity";
	my $waiting=0;
	unless (in_callback || envset "GENESIS_TESTING") {;
		waiting_on STDERR "Checking availability of the #M{%s} BOSH director...", $self->{alias};
		$waiting=1;
	}

	my $status = tcp_listening($self->{host},$self->{port});
	unless ($status eq 'ok') {
		error "#R{unreachable - $status!}\n" if $waiting;
		dump_stack;
		bail("\n#R{[ERROR]} Unable to connect to #M{%s} BOSH director...", $self->{alias});
	}

	my ($out,$rc,$err) = eval{$self->execute('env')};
	($err,$rc) = ($@,70)if ($@); # 70 is EX_SOFTWARE in sysexits.h,denoting internal software error
	if ($rc) {
		error "#R{error!}" if $waiting;
		bail("\n#R{[ERROR]} Unable to connect to #M{%s} BOSH director:\n%s", $self->{alias},$err);
	}
	if ($out =~ /\(not logged in\)/) {
		error "#R{unauthorized!}" if $waiting;
		bail(
			"\n#R{[ERROR]} Unable to connect to #M{%s} BOSH director: no active session.\n".
			"        Please log in and try again.",
			$self->{alias}
		)
	}
	($self->{user}) = $out =~ /^(.*)\z/m;
	explain STDERR "#G{ok} - authorized as #g{$self->{user}}" if $waiting;
	$self->{validated} = 1;
	$ENV{GENESIS_BOSH_VERIFIED} = $self->{alias};
	return $self;
}

# }}}
# download_confgs - download configuration(s) of the given type (and optional name) {{{
sub download_configs {
	my ($self, $path, $type, $name) = @_;
	$name ||= '*';

	my @configs;
	if ($name eq '*') {
		my ($out,$rc,$err) = $self->execute({interactive => 0},
			'configs -r=1 --type="$1" --json | jq -r \'.Tables[0].Rows[]| {"type": .type, "name": .name}\' | jq -sMc',
			$type
		);

		my $configs_list = eval {JSON::PP::decode_json($out) unless $rc};
		chomp(my $json_err = $@ || '');
		if ($rc || $json_err) {
			$json_err =~ s/ at lib\/Genesis\/BOSH.*//sm if $json_err;
			$err ||= $json_err || "bosh configs returned exit code $rc";
			bail("#R{[ERROR]} Could not determine available #C{$type} configurations: $err");
		}

		for (@$configs_list) {
			my $label = $_->{name} eq "default" ? "base $_->{type} config" : "$_->{type} config '$_->{name}'";
			push @configs, {type => $_->{type}, name => $_->{name}, label => $label};
		}
	} else {
		my $label = $name eq "default" ? "$type config" : "$type config '$name'";
		push @configs, {type => $type, name => $name, label => $label};
	}

	my @config_contents;
	for (@configs) {
		my ($out,$rc,$err) = $self->execute({ interactive => 0},
			'config', '--type', $_->{type}, '--name', $_->{name}, '--json'
		);

		my $json = eval {JSON::PP::decode_json($out) unless $rc};
		chomp(my $json_err = $@ || '');
		if ($rc || $json_err) {
			$json_err =~ s/ at lib\/Genesis\/BOSH.*//sm if $json_err;
			$err ||= $json_err || "bosh configs returned exit code $rc";
			bail("#R{[ERROR]} Could not determine available #C{$type} configurations: $err");
		}

		if ($rc || $json_err) {
			my $msg = $err;
			$msg = "#R{$json_err:}\n\n[36m$out[0m" if ($json_err && !$msg);
			$msg ||= join("\n", grep {$_ !~ /^Exit code/} grep {$_ !~ /^Using environment/} @{$json->{Lines}});
			$msg ||= "Could not understand 'BOSH config' json output:\n\n[36m$out[0m";
			$msg = "No $_->{label} found" if $msg eq 'No config';
			bail $msg;
		}

		bug("BOSH returned multiple entries for $_->label - Genesis doesn't know how to process this")
			if (@{$json->{Tables}} != 1 || @{$json->{Tables}[0]{Rows}} != 1);

		my $config = $json->{Tables}[0]{Rows}[0]{content};

		bail "No $_->{label} contents." unless $config;
		push @config_contents, $config;
	}
	my $config;
	if (scalar(@config_contents) > 1) {
		($config, my $rc, my $err) = run(
			{interactive => 0, stderr=>0},
			'spruce merge --multi-doc --go-patch <(echo "$1")',
			join("\n---\n", @config_contents)
		);
		bail("Failed to converge the active $type configurations: $err") if $rc;
	} else {
		$config = $config_contents[0]
	}
	mkfile_or_fail($path,$config || "");
	bail(
		"#R{[ERROR]}  No matching $type configurations defined on '#M{%s}' BOSH director", $self->alias
	) unless (-s $path);
	return wantarray ? @configs : \@configs;
}
# }}}
# deploy - deploy the given manifest as the deployment {{{
sub deploy {
	my ($self, $manifest, %opts) = @_;

	$opts{flags} ||= [];
	push(@{$opts{flags}}, "-l", $opts{vars_file}) if ($opts{vars_file});

	bug("No deployment name provided for BOSH Director in call to deploy()")
		unless $self->deployment;

	bug("Missing manifest in call to deploy()")
		unless $manifest;

	return $self->execute(
		{interactive => 1, passfail => 1 },
		'deploy', @{$opts{flags}}, $manifest
	);
}

# }}}
# run_errand - run an errand against the BOSH deployment {{{
sub run_errand {
	my ($self, $errand) = @_;

	bug("No deployment name provided for BOSH Director in call to run_errand()")
		unless $self->deployment;

	bug("Missing errand name in call to deploy()")
		unless $errand;

	$self->execute(
		{ interactive => 1, onfailure => "Failed to run errand '$errand' ($self->{deployment} deployment on $self->{alias} BOSH director)" },
		'-n', 'run-errand', $errand
	);

	return 1;
}

# }}}
# stemcells - list the present stemcells on the BOSH director {{{
sub stemcells {
	return lines($_[0]->execute(
		q<bosh stemcells --json | jq -r '.Tables[0].Rows[] | "\(.os)@\(.version)" | sub("[^0-9]+$";"")'>,
	));
}

# }}}
# }}}
1
# vim: fdm=marker:foldlevel=1:noet
