package Service::Credhub;
use strict;
use warnings;

use Genesis;
use Genesis::Term;
use Genesis::UI;
use JSON::PP qw/decode_json encode_json/;
use UUID::Tiny ();

### Class Methods {{{

# new - raw instantiation of a credhub object {{{
sub new {
	my ($class, $name, $base, $url, $username, $password, $ca_cert) = @_;
	return bless({
		name     => $name,
		base     => $base,
		url      => $url,
		username => $username,
		password => $password,
		ca_cert  => $ca_cert,
	}, $class)
}
# }}}
# from_bosh - create a credhub object from the BOSH director details {{{
sub from_bosh {
	my ($class, $bosh, %opts) = @_;
	my ($exodus, $exodus_source);
	$opts{vault} ||= (Service::Vault->current || Service::Vault->default);
	my $exodus_path = $opts{exodus_path} || $bosh->exodus_path;
	$exodus = $opts{vault}->get($exodus_path);
	$exodus_source = csprintf("under #C{%s} on vault #M{%s}", $exodus_path, $opts{vault}->name);
	unless ($exodus) {
		trace("#R{[ERROR]} No exodus data found %s", $exodus_source);
		return;
	}

	# validate exodus data
	my @missing_keys;
	for (qw(credhub_url credhub_username credhub_password credhub_ca_cert)) {
		push(@missing_keys,$_) unless $exodus->{$_};
	}
	if (@missing_keys) {
		trace(
			"#R{[ERROR]} Exodus data %s does not appear to be for a deployment ".
			"containing a CredHub endpoint:\n".
			"        Missing keys: %s",
			$exodus_source, join(", ", @missing_keys)
		);
		return;
	}
	return $class->new(
		$bosh->alias,
		$exodus->{credhub_base} || $opts{base} ||	"/",
		$exodus->{credhub_url},
		$exodus->{credhub_username},
		$exodus->{credhub_password},
		$exodus->{ca_cert}.$exodus->{credhub_ca_cert}
	);
}
# }}}
# }}}

### Instance Methods {{{
sub base {$_[0]->{base} =~ s/\/?\z/\//r};

sub env {
	my $self = shift;
	return {
		CREDHUB_SERVER  => $self->{url},
		CREDHUB_CLIENT  => $self->{username},
		CREDHUB_SECRET  => $self->{password},
		CREDHUB_CA_CERT => $self->{ca_cert}
	};
}

sub preload {
	my $self = shift;
	my ($out,$rc,$err) = run({
			env => $self->env(),
			redact_env => 1,
			redact_output => 1,
			stderr => 0
		},
		'credhub', 'export', '-j', '-p', $self->base
	);
	if ($rc) {
		delete($self->{cached});
	} else {
		my $data = read_json_from($out, $rc, $err);
		$self->{cached} = $rc ? {} : {(
			map {($_->{Name} =~ s/$self->{base}\///r, $_->{Value})} @{$data->{Credentials}}
		)};
	}
	return;
}

sub is_preloaded {
	my $self = shift;
	return defined($self->{cached}) && ref($self->{cached}) eq 'HASH' && scalar(keys %{$self->{cached}});
}

sub has {
	my ($self,$path,$key) = @_;
	if ($self->{cached} && exists($self->{cached}{$path})) {
		return !defined($key) || exists($self->{cached}{$path}{$key});
	}
	my $data = $self->data($path);
	return "" if !defined($data) || ref($data) ne 'HASH' || $data->{error};
	return defined($data->{value}) unless defined($key);
	return ref($data->{value}) eq 'HASH' && defined($data->{value}{$key});
}

sub get {
	my ($self,$path,$key) = @_;
	my $data = ($self->{cached} && exists($self->{cached}{$path}))
		? {value => $self->{cached}{$path}}
		: $self->data($path);
	my $value = defined($key) ? $data->{value}->{$key} : $data->{value};
	return wantarray ? ($value, $data->{error}) : $value;
}

sub data {
	my ($self,$path) = @_;
	my ($out,$rc,$err) = run({
			env => $self->env(),
			redact_env => 1,
			redact_output => 1,
			stderr => 0
		},
		'credhub', 'get', '-j', '-n', $self->_full_path($path)
	);
	$err = decolorize($err) =~ s/\AWARNING: Two different login methods were detected.*?\n\n\n//sr;
	return $rc ? {error => $err}: scalar(read_json_from($out,$rc,$err));
}

sub set {
	my ($self, $path, $value, $type) = @_;
	my @args = ();

	$type ||= (defined($value) && ref($value)) ? 'json' : 'value';
	if ($type eq 'certificate') {
		my @valid_keys = qw/certificate private_key root root_path/;
		my ($unused,$used,$invalid) = compare_arrays \@valid_keys, [keys %$value];
		my ($missing, $provided, $optional) = compare_arrays [qw/certificate private_key/], $used;

		# Need certificate and private_key, and one of ca or root_path.
		bail(
			"Invalid parameters specified for creating a CredHub certificate value: ".
			join(', ',@$invalid)
		) if @$invalid;
		bail(
			"You must supply either the certificate and the public_key when creating ".
			"a CredHub certificate value."
		) if @$missing;
		bail(
			"You must supply either the root ca certificate (root) or the CredHub path ".
			"to the root ca (root_path) when creating a certificate, but not both."
		) if scalar(@$optional) != 1;

		push @args, '-c', $value->{certificate};
		push @args, '-p', $value->{private_key};
		push @args, '-r', $value->{root} if defined($value->{root});
		push @args, '-m', $value->{root_path} if defined($value->{root_path});

	} elsif ($type eq 'ssh' || $type eq 'rsa') {
		my @valid_keys = qw/public_key private_key/;
		my ($missing,$provided,$invalid) = compare_arrays \@valid_keys, [keys %$value];

		bail(
			"Invalid parameters specified for creating a CredHub %s value: %s",
			uc($type), join(', ',@$invalid)
		) if @$invalid;
		bail(
			"You must supply the %s  when creating a Credhub %s value",
			sentence_join(@valid_keys), uc($type)
		) if @$missing;

		push @args, '-u', $value->{public_key};
		push @args, '-p', $value->{private_key};

	} elsif ($type eq 'user' || $type eq 'password') {
		my @valid_keys = ('password');
		push @valid_keys, 'username' if $type eq 'user';
		my ($missing,$provided,$invalid) = compare_arrays \@valid_keys, [keys %$value];

		bail(
			"Invalid parameters specified for creating a CredHub %s value: %s",
			uc($type), join(', ',@$invalid)
		) if @$invalid;
		bail(
			"You must supply the %s  when creating a Credhub %s value",
			sentence_join(@valid_keys), uc($type)
		) if @$missing;

		push @args, '-z', $value->{username} if defined($value->{username});
		push @args, '-w', $value->{password};

	} elsif ($type eq 'json') {
		bail(
			"You must specify a HASH or an ARRAY as the value when creating a CredHub ".
			"json value"
		) unless ref($value) =~ /^(ARRAY|HASH)$/;
		push @args, '-v', {redact => encode_json($value)};

	} elsif ($type eq 'value') {
		bail(
			"You must specify a HASH or an ARRAY as the value when creating a CredHub ".
			"json value"
		) unless defined($value) and ref($value) eq '';
		$value =~ s/\$/\${__dollar_symbol__}/g if $value =~ /\$/;
		push @args, '-v', {redact => $value};

	} else {
		bail(
			"Unknown CredHub type: $type - expecting one of: certificate, rsa, ssh, ".
			"user, password, json, or value"
		);
	}
	unshift @args, "-n", $self->_full_path($path), "-t", $type;
	my ($out,$rc, $err) =run({
			env => {
				%{$self->env()},
				__dollar_symbol__ => '$'
			},
			redact_output => 1,
			redact_env => 1,
			stderr => 0
		},
		'credhub', 'set', '-j', @args
	);
	bail(
		"Could not create the Credhub %s value:\n%s\n[Exit Code: %s]",
		$type,$out,$rc
	) if $rc;
	my $result = read_json_from($out, $rc, $err);
	# TODO: update cache if it exists
	return ($result->{id});
}

sub paths {
	my ($self,$filter) = @_;
	my @filter = ();
	if (!  defined($filter)) {
		push(@filter, '-n', $self->{base}.'/');
	} elsif ($filter && ref($filter) ne "") {
		push(@filter, '-n', $self->_full_path($filter));
	}

	my $paths = read_json_from(run({
			env => $self->env(),
			redact_env => 1,
			stderr => 0,
		},
		'credhub', 'find', '-j', @filter
	));
	return
	  grep {ref($filter) ne "Regexp" || $_ =~ $filter}
	  map {$_->{name}}
		@{$paths->{credentials}};
}

sub keys {
	bug "Service::Credhub::keys method not supported";
}

sub delete {
	my ($self,$name) = @_;
	return run({
			env => $self->env(),
			redact_env => 1,
			stderr => 0
		},
		'credhub', 'delete', '--name', $self->_full_path($name)
	);
}

sub delete_all {
	my ($self,$path) = @_;
	return run({
			env => $self->env(),
			redact_env => 1,
			stderr => 0
		},
		'credhub', 'delete', '--path', $self->_full_path($path)
	);
}

sub query {
	my ($self,$path,%params) = @_;
	
	my @args;
	push @args, '-X', uc(delete($params{_method}))
		if defined $params{_method};
	push @args, '-d', delete($params{data})
		if defined $params{_data};
	# TODO: extract uri-encoded query params out of %params
	return scalar(read_json_from(run({
			env => $self->env(),
			redact_env => 1,
			stderr => 0
		},
		'credhub', 'curl', '--path', "$path", @args
	)));
}

sub _full_path {
	my ($self,$path) = @_;
	return $self->{base} unless $path;
	return $path if ($path =~ /^\//);
	return ($self->{base}).'/'.$path;
}

sub execute {
	my ($self,$cmd,@args) = @_;
	return run({
			env => $self->env(),
			interactive => 1,
			redact_env => 1,
			stderr => 0
		},
		'credhub', $cmd, @args
	);
}

# TODO: export, import
# }}}
1;
