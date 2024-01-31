package Genesis::Secret::X509;
use strict;
use warnings;

use base "Genesis::Secret";

use Genesis qw/uniq run bug compare_arrays/;
use Genesis::State qw/envset/;
use Time::Piece;

### Construction arguments {{{
# is_ca:     <boolean, optional: cert if a ca cert if true>
# base_path: <relative path that shares a ca>
# signed_by: <optional: specifies signing ca path>
# valid_for: <optional: integer, followed by [ymdh], for years, months, days or hours>
# names:     <array, optional>
# usage:     <array, list of key and extended key usage>
# }}}

### Class Properties {{{
my $keyUsageLookup = { # {{{
  "Digital Signature" =>  "digital_signature",
  "Non Repudiation" =>    "non_repudiation",
  "Content Commitment" => "content_commitment", #Newer version of non_repudiation
  "Key Encipherment" =>   "key_encipherment",
  "Data Encipherment" =>  "data_encipherment",
  "Key Agreement" =>      "key_agreement",
  "Certificate Sign" =>   "key_cert_sign",
  "CRL Sign" =>           "crl_sign",
  "Encipher Only" =>      "encipher_only",
  "Decipher Only" =>      "decipher_only",
};
# }}}
my $extendedKeyUsageLookup = { # {{{
  "TLS Web Client Authentication" => "client_auth",
  "TLS Web Server Authentication" => "server_auth",
  "Code Signing" =>                  "code_signing",
  "E-mail Protection" =>             "email_protection",
  "Time Stamping" =>                 "timestamping"
};
# }}}
# }}}

### Class Methods {{{
# new - initialize a new X.509 secret (special ordered property) {{{
sub new {
  my $class = shift;
  my $obj = $class->SUPER::new(@_);
  $obj->{signed} = 0; # Does this serve a purpose or cargo-culted?
	$obj->{ordered} = 0;
  return $obj;
}

# }}}
# }}}

### Instance Methods {{{
# ordered - set or check if secret is ordered correctly. {{{
sub ordered {
	defined($_[1]) ? $_[0]->{ordered} = ($_[1]?1:0) : $_[0]->{ordered}
}

# }}}
# read_names - read the stored names (to get previously generated ca names) {{{
sub read_names {
	my $self = shift;
	$self->has_value or $self->plan->store->read($self);
	return () unless $self->value and $self->value->{certificate};

	my $cert = $self->value->{certificate};
	my $certInfo = run('openssl x509 -in <(echo "$1") -text -fingerprint -modulus -noout', $cert);
	my ($issuerCN, $since, $expires, $subjectCN, $fingerprint, $modulus) =
		$certInfo =~ /Issuer: (?:[^\r\n]+?, )?CN\s*=\s*([^\r\n]+).*Not Before: ([^\r\n]*).*Not After : ([^\n]*).*Subject: (?:[^\r\n]+?, )?CN\s*=\s*([^\r\n]+?)\s*[\r\n]+.*Fingerprint=(\S*).*Modulus=(\S*)/ms;
	my $is_ca = $certInfo =~ /X509v3 Basic Constraints:.*(CA:TRUE).*Signature Algorithm/ms;
	my (undef, $sanInfo) = $certInfo =~ /\n( *)X509v3 Subject Alternative Name:\s*?((?:[\n\r]+\1.*)+)/;
	my @SANs = ($sanInfo || '') =~ /(?:IP Address|DNS):([^,\n\r]+)/g;
	@SANs =  map {s/\s*$//; $_} @SANs;
	return uniq($subjectCN,@SANs);
}

# }}}
# ca - return the ca secret for the certificate {{{
sub ca {
	my $self = shift;
	return $self if $self->get('self_signed');
	return $self->plan->secret_at($self->get('signed_by'));
}

# }}}
# vault_operator - get the vault operator string for the given key {{{
sub vault_operator {
	my ($self, $key) = @_;
	my $path = $self->path;
	if (!defined($key)) {
		return {map {($_, $self->vault_operator($_))} qw/ca certificate private_key/};
	} elsif ($key eq 'certificate') {
		$path .= ':certificate'
	} elsif ($key eq 'private_key' || $key eq 'key') {
		$path .= ':key';
	} elsif ($key eq 'ca') {
		my $ca_path = $self->get('signed_by');
		if ($ca_path =~ /^\//) {
			$path = "$ca_path:certificate"
		} else {
			return $self->ca->vault_operator('certificate')
		}
	} else {
		bug(
			"Invalid key for vault_operator on %s secret", $self->type
		)
	}
	return $self->_assemble_vault_operator($path);
}
# }}}
# }}}

### Polymorphic Instance Methods {{{
# label - specific label for this derived class {{{
sub label {"X.509 Certificate"}

# }}}
# }}}

### Parent-called Support Instance Methods {{{
# _description - return label and features to build describe output {{{
sub _description {
	my $self = shift;

	my @features = (
		$self->get('is_ca') ? 'CA' : undef,
		$self->get('self_signed')
			? ($self->get('self_signed') == 2 ? 'explicitly self-signed' : 'self-signed')
			: ($self->get('signed_by') ? "signed by '".$self->get('signed_by')."'" : undef )
	);
	return ($self->label, @features);
}

# }}}
# _required_value_keys - list of required keys in value store {{{
sub _required_value_keys {
	my @keys = qw(certificate combined key);
	push(@keys, qw(crl serial)) if$_[0] && $_[0]->get('is_ca');
	return @keys;
}

# }}}
# _validate_constructor_opts - make sure secret definition is valid {{{
sub _validate_constructor_opts {
	my ($self,$path,%opts) = @_;

	my @errors;
	my %orig_opts = %opts;
	my $args = {};

	if (defined($opts{valid_for})) {
		if ($opts{valid_for} =~ /^[1-9][0-9]*[ymdh]$/) {
			$args->{valid_for} = delete($opts{valid_for});
		} else {
			push(@errors, "Invalid valid_for argument: expecting <positive_number>[ymdh], got $opts{valid_for}");
		}
	}

	# names
	$args->{subject_cn} = delete($opts{subject_cn}) if defined($opts{subject_cn});

	if (defined($opts{names})) {
		if (ref($opts{names}) eq 'HASH') {
			push @errors, "Invalid names argument: expecting an array of one or more strings, got a hashmap";
		} elsif (ref($opts{names}) eq '') {
			push @errors, "Invalid names argument: expecting an array of one or more strings, got the string '$opts{names}'"
		} elsif (ref($opts{names}) eq 'ARRAY') {
			if (! scalar @{$opts{names}}) {
				push @errors, "Invalid names argument: expecting an array of one or more strings, got an empty list"
					unless $args->{subject_cn};
			} elsif (grep {!$_} @{$opts{names}}) {
				push @errors, "Invalid names argument: cannot have an empty name entry";
			} elsif (grep {ref($_) ne ""} @{$opts{names}}) {
				push @errors, "Invalid names argument: cannot have an entry that is not a string";
			}
		}
		$args->{names} = delete($opts{names});
	}

	if (defined($opts{usage}) || defined($opts{key_usage})) {
		my $usage = delete($opts{usage}) || delete($opts{key_usage}); # key_usage will show up as invalid if both are used, rendering it deprecated
		if (ref($usage) eq 'ARRAY') {
			my %valid_keys = map {$_, 1} _key_usage_types();
			my @invalid_keys = grep {!$valid_keys{$_}} @{$usage};
			push @errors, sprintf("Invalid usage argument - unknown usage keys: '%s'\n[[Valid keys are: >>'%s'",
				join("', '", sort @invalid_keys), join("', '", sort(keys %valid_keys)))
			if (@invalid_keys);
		} else {
			push @errors, "Invalid usage argument: expecting an array of one or more strings, got ".
			(ref($usage) ? lc('a '.ref($usage)) : "the string '$usage'");
		}
		$args->{usage} = $usage;
	}

	if (defined($opts{is_ca})) {
		push @errors, "Invalid is_ca argument: expecting boolean value, got '$opts{is_ca}'"
		unless $opts{is_ca} =~ /^1?$/;
		$args->{is_ca} = delete($opts{is_ca});
	}

	push(@errors, "Non-CA certificates must supply at least one name")
		if (!$args->{is_ca} && ! @{$args->{names}//[]});

	$args->{signed_by} = delete($opts{signed_by}) if defined($opts{signed_by});
	$args->{base_path} = delete($opts{base_path});

	if ($args->{signed_by} && $args->{signed_by} !~ /^[a-z0-9_-]+(\/[a-z0-9_-]+)?$/i) {
		push @errors, "Invalid signed_by argument: expecting relative vault path string, got '$args->{signed_by}'"
	}

	push(@errors, "Invalid '$_' argument specified") for grep {defined($opts{$_})} keys(%opts);
	return @errors
	? (\%orig_opts, \@errors)
	: ($args)

}

# }}}
# _validate_value - validate an x509 secret value {{{
sub _validate_value {
	my ($self) = @_;
	my $values = $self->value;
	my $root_path = $self->base_path;
	# TODO: Maybe we want $self->ca_values as a special alternative value - for
	#       now were just reaching back into the store, but this will decouple it
	#
	my %results;

	# Get Cert Info
	my $key  = $values->{key};
	my $cert = $values->{certificate};
	my ($keyModulus) = run('openssl rsa -in <(echo "$1") -modulus  -noout', $key) =~ /Modulus=(\S*)/;
	my $certInfo = run('openssl x509 -in <(echo "$1") -text -fingerprint -modulus -noout', $cert);
	my ($issuerCN, $since, $expires, $subjectCN, $fingerprint, $modulus) =
		$certInfo =~ /Issuer: (?:[^\r\n]+?, )?CN\s*=\s*([^\r\n]+).*Not Before: ([^\r\n]*).*Not After : ([^\n]*).*Subject: (?:[^\r\n]+?, )?CN\s*=\s*([^\r\n]+?)\s*[\r\n]+.*Fingerprint=(\S*).*Modulus=(\S*)/ms;
	my $is_ca = $certInfo =~ /X509v3 Basic Constraints:.*(CA:TRUE).*Signature Algorithm/ms;
	my (undef, $sanInfo) = $certInfo =~ /\n( *)X509v3 Subject Alternative Name:\s*?((?:[\n\r]+\1.*)+)/;
	my @SANs = ($sanInfo || '') =~ /(?:IP Address|DNS):([^,\n\r]+)/g;
	@SANs =  map {s/\s*$//; $_} @SANs;

	# Validate CN if kit requests on explicitly
	my $cn_str = $self->get(subject_cn => ${$self->get('names')||[]}[0]);
	my $base_path = $self->get('base_path');
	if ($cn_str) { # && $cn_str !~ /^ca\.n[0-9]{9}\.$base_path$/ ) {
		my $match = $subjectCN eq $cn_str;
		$results{cn} = [
			$match ? 'ok' : 'warn',
			sprintf("Subject Name '%s'%s", $cn_str, $match ? '' : " (found '$subjectCN')")
		];
	}

	# Validate SAN
	# Note: We no longer validate CA SANs
	unless ($self->get('is_ca')) {
		my (%sans,%desired_sans);
		my @names = @{$self->get('names')||[]};
		my ($extra_sans, undef, $missing_sans) = compare_arrays(\@SANs, \@names);
		if (!scalar(@$extra_sans) && !scalar(@$missing_sans)) {
			$results{san} = ['ok', 'Subject Alt Names: '.(@SANs ? join(", ",map {"'$_'"} @{$self->get('names')}) : '#i{none}')]
				if scalar(@SANs);
		} else {
			$results{san} = ['warn', 'Subject Alt Names ('. join('; ',(
				@$missing_sans ? "missing: ".join(", ", @$missing_sans):(),
				@$extra_sans? "extra: ".join(", ", @$extra_sans) : ()
			)).")"];
		}
	}

	# Signage and Modulus Agreement
	if ($self->get('is_ca')) {
		$results{is_ca} = [ !!$is_ca, "CA Certificate" ];
	} else {
		$results{is_ca} = [ !$is_ca ? 'ok' : 'warn', 'Not a CA Certificate' ];
	}

	my ($subjectKeyID) = $certInfo =~ /X509v3 Subject Key Identifier: *[\n\r]+\s+([A-F0-9:]+)\s*$/m;
	my ($authKeyID)    = $certInfo =~ /X509v3 Authority Key Identifier: *[\n\r]+\s+(?:keyid:)?([A-F0-9:]+)\s*$/m;
	my $signed_by_str;
	my $self_signed = (!$self->get('signed_by') || $self->get('signed_by') eq $self->path);
	if ($self_signed) {
		$results{self_signed} = [
			($subjectKeyID && $authKeyID)	? $subjectKeyID eq $authKeyID : $issuerCN eq $subjectCN,
			"Self-Signed"
		];
	} else {
		my $all_secrets = $self->plan->store->store_data;
		my $signer_path = $self->get('signed_by');
		my $signer_full_path = $root_path . $signer_path unless $signer_path =~ /^\//;
		$signer_full_path =~ s/^\///;
		if ($all_secrets->{$signer_full_path}) {
			my $ca_cert = $self->plan->store->store_data->{$signer_full_path}{certificate};
			my $caSubjectKeyID;
			if ($authKeyID) {
				# Try to use the subject and authority key identifiers if they exist
				my $caInfo = run('openssl x509 -in <(echo "$1") -text -noout', $ca_cert);
				($caSubjectKeyID) = $caInfo =~ /X509v3 Subject Key Identifier: *[\r\n]+\s+([A-F0-9:]+)\s*$/m;
			}
			if ($caSubjectKeyID) {
				$results{signed} = [
					$authKeyID eq $caSubjectKeyID,
					"Signed by ".$self->get('signed_by')
				];
			} else {
				# Otherwise try to validate the full chain if we have access all the certs
				my $ca_secret;
				my $full_cert_chain='';
				while (1) {
					last unless $signer_full_path && defined($all_secrets->{$signer_full_path});
					$full_cert_chain =  $all_secrets->{$signer_path}{certificate}.$full_cert_chain;

					$ca_secret = $self->plan->secret_at($signer_path);
					last unless ($ca_secret && $ca_secret->get('signed_by'));

					$signer_path = $ca_secret->get('signed_by');
					$signer_full_path = $root_path . $signer_path unless $signer_path =~ /^\//;
					$signer_full_path =~ s/^\///;
				}

				my $out = run(
					'openssl verify -verbose -CAfile <(echo "$1") <(echo "$2")',
					$full_cert_chain, $values->{certificate}
				);
				my $signed;
				if ($out =~ /error \d+ at \d+ depth lookup/) {
					#fine, we'll check via safe itself - last resort because it takes time
					my $signer_path = $self->get('signed_by');
					my $signer_full_path = $root_path . $signer_path unless $signer_path =~ /^\//;
					$signer_full_path =~ s/^\///;
					my ($safe_out,$rc) = $self->plan->env->vault->query('x509','validate','--signed-by', $signer_full_path, $root_path.$self->path);
					$signed = $rc == 0 && $safe_out =~ qr/$self->path checks out/;
				} else {
					$signed = $out =~ /: OK$/;
				}
				$results{signed} = [
					$signed,
					sprintf("Signed by %s%s", $self->get('signed_by'), $signed ? '' : (
						$subjectCN eq $issuerCN ? " (maybe self-signed?)" : "  (signed by CN '$issuerCN')"
					))
				];
			}
		} else {
			$results{signed} = [
				'error',
				sprintf("Signed by %s (specified CA not found - %s)", $self->get('signed_by'),
					($subjectCN eq $issuerCN ? "maybe self-signed?" : "found signed by CN '$issuerCN'")
				)
			];
		}
	}

	$results{modulus_agreement} = [$modulus eq $keyModulus, "Modulus Agreement"];

	# Validate TTL
	my $now_t = Time::Piece->new();
	my $since_t   = Time::Piece->strptime($since,   "%b %d %H:%M:%S %Y %Z");
	my $expires_t = Time::Piece->strptime($expires, "%b %d %H:%M:%S %Y %Z");
	my $valid_str;
	my $days_left;
	if ($since_t < $now_t) {
		if ($now_t < $expires_t) {
			$days_left = ($expires_t - $now_t)->days();
			$valid_str = sprintf("expires in %.0f days (%s)",  ($expires_t - $now_t)->days(), $expires);
		} else {
			$valid_str = sprintf("expired %.0f days ago (%s)", ($now_t - $expires_t)->days(), $expires);
		}
	} else {
		$valid_str = "not yet valid (starts $since)";
	}
	$results{valid} = [$valid_str =~ /^expires/ ? ($days_left > 30 ? 'ok' : 'warn') : 'error', "Valid: ".$valid_str];

	# Validate Usage
	$results{usage} = $self->_check_usage($certInfo);

	return (\%results, qw/is_ca self_signed signed valid modulus_agreement cn san usage/);
}

# }}}
# _get_safe_command_for_add - get command components for add secret {{{
sub _get_safe_command_for_add {
	my ($self) = @_;
	my @names = @{$self->get('names') || []};
	@names = (sprintf("ca.n%09d.%s", rand(1000000000),$self->get('base_path')))
		if $self->get('is_ca') && ! scalar(@names) && ! $self->get('subject_cn');

	my @cmd = $self->_base_safe_command('issue', @names);
	push(@cmd, '--ca') if $self->get('is_ca');
	push(@cmd, '--no-clobber');
	return @cmd
}

# }}}
# _get_safe_command_for_rotate - get command components for rotating secret {{{
sub _get_safe_command_for_rotate {
	my ($self, %opts) = @_;
	return $self->_get_safe_command_for_add unless $self->has_value;
	my @names = @{$self->get('names') || []};

	# If no name and ca, then try to read the autogenerated one from previous creation
	@names = $self->read_names
		if $self->get('is_ca') && ! scalar(@names) && ! $self->get('subject_cn');

	my $action = 'renew';
	if ($opts{'regen-x509-keys'}) {
		my $value = $self->value || $self->plan->store->read->value;
		$action = 'issue' if ($value && $value->{key});
	}
	my @cmd = $self->_base_safe_command($action, @names);
	if ($action eq 'issue') {
		push(@cmd, '--ca') if $self->get('is_ca');
		push(@cmd, '--no-clobber') if $self->get(fixed => 0);
	} else {
		my $cert_name = $self->get(subject_cn => $names[0]);
		push(@cmd, '--subject', "cn=$cert_name")
			if $opts{update_subject} || envset("GENESIS_RENEW_SUBJECT");
	}
	return @cmd
}

# }}}
# _import_from_credhub - import secret values from credhub {{{
sub _import_from_credhub {
	my ($self,$value) = @_;
	# TODO: Do we need to check if the ca cert is the ca cert associated?
	#
	return ('error', 'expecting a hash, got a '.(ref($value)//'null'||('string "'.$value//''.'"')))
		if ref($value) ne 'HASH';
	my @missing = grep {!exists($value->{$_})} qw/certificate private_key/;
	return ('error', "missing keys in credhub secret: ".join(", ", @missing))
		if @missing;

	$self->set_value({
		certificate => $value->{certificate},
		key => $value->{private_key},
		combined => $value->{certificate}.$value->{private_key}
	});
	$self->save;

	return ('ok') unless $self->get('is_ca');

	# Generate the serial and crl that credhub doesn't provide
	my @cmd = (qw(x509 renew), $self->full_path);
	if (my $signed_by = $self->get('signed_by')) {
		$signed_by = $self->base_path.$signed_by unless $signed_by =~ /^\//;
		push(@cmd, '--signed-by', $signed_by);
	}
	my ($out, $rc, $err) = $self->plan->store->service->query(@cmd);
	return ('error', $out."\n".$err) unless $rc == 0 && $out =~ /^\s*Renewed x509 certificate at/;

	# load secret and check that it contains crl and serial
	$self->load();
	return ('error', 'could not generate crl or serial values for ca cert')
		unless (exists($self->value->{crl}) && exists($self->value->{serial}));

	# Restore the certificate
	$self->value->{certificate} = $value->{certificate};
	$self->value->{combined} =  $value->{certificate}.$value->{private_key};
	$self->save; #TODO: or return error?

	return ('ok');
}

# }}}
# }}}

### Private Instance Methods {{{
# _key_usage_types - return list of usage types {{{
sub _key_usage_types {
	return uniq(values %{$keyUsageLookup}, values %{$extendedKeyUsageLookup});
}
# }}}
# _expected_usage - get the usage and its description for a given x509 plan {{{
sub _expected_usage {
	my $self = shift;
	my $usage = $self->get('usage');
	my $usage_str = undef;
	my $usage_type = 'warn'; # set to 'error' for mismatch enforcement
	if (defined($usage)) {
		$usage_str = scalar(@$usage) ? "Specified key usage" : "No key usage";
	} elsif ($self->get('is_ca')) {
		$usage_type = 'warn';
		$usage = [qw/server_auth client_auth crl_sign key_cert_sign/];
		$usage_str = "Default CA key usage";
	} else {
		$usage_type = 'warn';
		$usage = [qw/server_auth client_auth/];
		$usage_str = "Default key usage";
	}
	return ($usage, $usage_str, $usage_type);
}

# }}}
# _get_usage_matrix_from_text - get usage from openssl (validate_secret) {{{
sub _get_usage_matrix_from_text {
  my ($self, $openssl_text) = @_;

	my %found = ();
	my ($specified_keys) = $openssl_text =~ /X509v3 Key Usage:.*[\n\r]+\s*([^\n\r]+)/;
	my ($specified_ext)  = $openssl_text =~ /X509v3 Extended Key Usage:.*[\n\r]\s*+([^\n\r]+)/;

	if ($specified_keys) {
		my @keys =  split(/,\s+/,$specified_keys);
		chomp @keys;
		$found{$_} = 1 for (grep {$_} map {$keyUsageLookup->{$_}} @keys);
	}
	if ($specified_ext) {
		my @keys =  split(/,\s+/,$specified_ext);
		chomp @keys;
		$found{$_} = 1 for (grep {$_} map {$extendedKeyUsageLookup->{$_}} @keys);
	}
  return %found;

}

# }}}
# _check_usage - check usage against expected (validate_secret) {{{
sub _check_usage {
  my ($self,$openssl_text) = @_;

  my ($expected, $usage_str, $usage_type) = $self->_expected_usage();
  my %found = $self->_get_usage_matrix_from_text($openssl_text);
	my @found = sort(grep {$found{$_}} keys %found);

	$found{$_}-- for uniq(@$expected);
	if ( exists($found{non_repudiation}) && exists($found{content_commitment}) &&
	     (abs($found{non_repudiation} + $found{content_commitment}) < 1)) {
		# if both non_repudiation and content_commitment are found and/or requested,
		# then as long is the total sum is less than |1|, it is considered requested
		# and found (ie not both requested and none found or both found and none requested)
		$found{non_repudiation} = $found{content_commitment} = 0;
	}
	my @extra   = sort(grep {$found{$_} > 0} keys %found);
	my @missing = sort(grep {$found{$_} < 0} keys %found);

	return ['ok', $usage_str . (@$expected ? ": ".join(", ", @$expected) : '')]
		unless @extra || @missing;

	$usage_type = 'warn' unless (@found); # no enforcement if no keys specified

	return [
		$usage_type,
		$usage_str . " (". join('; ',(
			@missing ? "missing: ".join(", ", @missing):(),
			@extra   ? "extra: "  .join(", ", @extra  ):()
		)).")"
	];
}

# }}}
# _base_safe_command - common command components for add, recreate and renew {{{
sub _base_safe_command {
	my ($self, $action, @names) = @_;
	my @cmd = (
		'x509',
		$action,
		$self->full_path,
		'--ttl', $self->get(valid_for => ($self->get('is_ca') ? '10y' : '3y'))
	);
	if (my $signed_by = $self->get('signed_by')) {
		$signed_by = $self->base_path.$signed_by unless $signed_by =~ /^\//;
		push(@cmd, '--signed-by', $signed_by);
	}
	# CAs shouldn't have SANs, apparently...
	if ($self->get('is_ca')) {
		my $subject_cn = $self->get(subject_cn => $names[0]);
		push(@cmd, '--subject', "cn=".$subject_cn);
		push(@cmd, '--name', $subject_cn); # Temporary hack untill safe supports SANs-less CAs
	} else {
		if ($action eq 'issue') {
			my $subject_cn = $self->get('subject_cn');
			push(@cmd, '--subject', "cn=".$subject_cn) if $subject_cn;
		}
		push(@cmd, '--name', $_) for @names;
	}

	my ($usage) = $self->_expected_usage;
	if (ref($usage) eq 'ARRAY') {
		push(@cmd, '--key-usage', $_) for (@{$usage} ? @{$usage} : qw/no/);
	}
	return @cmd;
}

# }}}
# }}}

1;
# vim: fdm=marker:foldlevel=1:noet
