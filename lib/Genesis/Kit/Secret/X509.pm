package Genesis::Kit::Secret::X509;
use strict;
use warnings;

use Genesis (qw/uniq/);

use base "Genesis::Kit::Secret";

=construction arguments
is_ca: <boolean, optional: cert if a ca cert if true> 
base_path:  <relative path that shares a ca>
signed_by: <optional: specifies signing ca path>
valid_for: <optional: integer, followed by [ymdh], for years, months, days or hours>
names: <array, optional>
usage: <array, list of key and extended key usage>
fixed: <boolean to specify if the secret can be overwritten>
=cut

my $keyUsageLookup = {
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

my $extendedKeyUsageLookup = {
  "TLS Web Client Authentication" => "client_auth",
  "TLS Web Server Authentication" => "server_auth",
  "Code Signing" =>                  "code_signing",
  "E-mail Protection" =>             "email_protection",
  "Time Stamping" =>                 "timestamping"
};

sub new {
  my $class = shift;
  my $obj = $class->SUPER::new(@_);
  $obj->{signed} = 0;
  return $obj;
}

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
  if (defined($opts{names})) {
    if (ref($opts{names}) eq 'HASH') {
      push @errors, "Invalid names argument: expecting an array of one or more strings, got a hashmap";
    } elsif (ref($opts{names}) eq '') {
      push @errors, "Invalid names argument: expecting an array of one or more strings, got the string '$opts{names}'"
    } elsif (ref($opts{names}) eq 'ARRAY') {
      if (! scalar @{$opts{names}}) {
        push @errors, "Invalid names argument: expecting an array of one or more strings, got an empty list";
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
      push @errors, sprintf("Invalid usage argument - unknown usage keys: '%s'\n  Valid keys are: '%s'",
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

  $args->{signed_by} = delete($opts{signed_by}) if defined($opts{signed_by});
  $args->{base_path} = delete($opts{base_path});

  push(@errors, "Invalid '$_' argument specified") for grep {defined($opts{$_})} keys(%opts);
  return @errors
    ? (\%orig_opts, \@errors)
    : ($args)

}

sub _description {
  my $self = shift;

  my @features = (
		$self->{definition}{is_ca} ? 'CA' : undef,
		$self->{definition}{self_signed}
			? ($self->{definition}{self_signed} == 2 ? 'explicitly self-signed' : 'self-signed')
			: ($self->{definition}{signed_by} ? "signed by '$self->{signed_by}'" : undef )
	);
  return ('X509 certificate', @features);
}

sub _key_usage_types {
	return uniq(values %{$keyUsageLookup}, values %{$extendedKeyUsageLookup});
}

sub _get_usage_matrix_from_value {
  my $self = shift;
  my $openssl_text = $self->openssl_output();

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
sub usage {
  my %found_matrix = $_[0]->_get_usage_matrix_from_value();
	return keys(%found_matrix);
}

sub check_usage {
  my $self = shift;

  my ($expected, undef, undef) = $self->expected_usage();
  my %found = $self->_get_usage_matrix_from_value();
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

	return {
		extra =>   (@extra   ? \@extra   : undef),
		missing => (@missing ? \@missing : undef),
		found =>   (@found   ? \@found   : undef)
	}
}
# }}}

sub expected_usage {
  my $self = shift;
	my ($usage, $usage_str);
	my $usage_type = 'warn'; # set to 'error' for mismatch enforcement
	if (defined($self->{definition}{usage})) {
		$usage = ($self->{definition}{usage});
		$usage_str = "Specified key usage";
		if (!scalar @$usage) {
			$usage_str = "No key usage";
		}
	} elsif ($self->{definition}{is_ca}) {
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

1;