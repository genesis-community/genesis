#!perl
use strict;
use warnings;

use Expect;
use lib 't';
use helper;
use Cwd qw(abs_path);

vault_ok;

bosh2_cli_ok;

my $dir = workdir 'redis-deployments';
chdir $dir or die;

reprovision init => 'redis',
            kit => 'omega';

diag "\rConnecting to the local vault (this may take a while)...";
expects_ok 'new-omega us-east-sandbox --vault unit-tests';

my $sec;
my $v = "secret/us/east/sandbox/omega";

my $rotated = [qw[
  test/random:username
  test/random:password
  test/random:limited

  test/ssh/strong:public
  test/ssh/strong:private
  test/ssh/strong:fingerprint

  test/ssh/meh:public
  test/ssh/meh:private
  test/ssh/meh:fingerprint

  test/ssh/weak:public
  test/ssh/weak:private
  test/ssh/weak:fingerprint

  test/rsa/strong:public
  test/rsa/strong:private

  test/rsa/meh:public
  test/rsa/meh:private

  test/rsa/weak:public
  test/rsa/weak:private

  test/fmt/sha512/default:random
  test/fmt/sha512/default:random-crypt-sha512

  test/fmt/sha512/at:random
  test/fmt/sha512/at:cryptonomicon

  auth/cf/uaa:shared_secret
]];

my $removed = [qw[
  test/random:username

  test/rsa/strong:public
  test/rsa/strong:private

  test/fixed/ssh:public
  test/fixed/ssh:private
  test/fixed/ssh:fingerprint
  
  test/fmt/sha512/default:random
  test/fmt/sha512/default:random-crypt-sha512
]];

my $fixed = [qw[
  test/fixed/random:username

  test/fixed/ssh:public
  test/fixed/ssh:private
  test/fixed/ssh:fingerprint

  test/fixed/rsa:public
  test/fixed/rsa:private

  auth/cf/uaa:fixed
]];

my %before;
for (@$rotated, @$fixed) {
  have_secret "$v/$_";
  $before{$_} = secret "$v/$_";
}
no_secret "$v/auth/github/oauth:shared_secret",
  "should not have secrets from inactive subkits";

is length($before{'test/random:username'}), 32,
  "random secret is generated with correct length";

is length($before{'test/random:password'}), 109,
  "random secret is generated with correct length";

like secret("$v/test/random:limited"), qr/^[a-z]{16}$/, "It is possible to limit chars used for random credentials";

runs_ok "genesis secrets rotate us-east-sandbox --vault unit-tests";
my %after;
for (@$rotated, @$fixed) {
  have_secret "$v/$_";
  $after{$_} = secret "$v/$_";
}

for (@$rotated) {
  isnt $before{$_}, $after{$_}, "$_ should be rotated";
}
for (@$fixed) {
  is $before{$_}, $after{$_}, "$_ should not be rotated";
}

%before = %after;
runs_ok "genesis secrets rotate --force us-east-sandbox --vault unit-tests";
for (@$rotated, @$fixed) {
  have_secret "$v/$_";
  $after{$_} = secret "$v/$_";
}
for (@$rotated, @$fixed) {
  isnt $before{$_}, $after{$_}, "$_ should be rotated (all)";
}

# Test that nothing is missing
my ($pass,$rc,$msg) = runs_ok "genesis secrets check us-east-sandbox --vault unit-tests";
matches $msg, qr/All credentials and certificates present./, "No missing secrets";

# Test only missing secrets are regenerated
%before = %after;
for (@$removed) {
  runs_ok "safe delete -f $v/$_", "removed $v/$_  for testing";
  no_secret "$v/$_", "$v/$_ should not exist";
}
($pass,$rc,$msg) = run_fails "genesis secrets check us-east-sandbox --vault unit-tests", 1;
matches $msg, qr#Missing 8 credentials or certificates:#, "Correct number of secrets reported missing";
matches $msg, qr#  \* \[random\] $v/test/random:username#, "Random-type secret missing";
matches $msg, qr#  \* \[rsa\] $v/test/rsa/strong:public#, "RSA-type public secret missing";
matches $msg, qr#  \* \[rsa\] $v/test/rsa/strong:private#, "RSA-type private secret missing";
matches $msg, qr#  \* \[ssh\] $v/test/fixed/ssh:public#, "SSH-type public secret missing";
matches $msg, qr#  \* \[ssh\] $v/test/fixed/ssh:private#, "SSH-type private secret missing";
matches $msg, qr#  \* \[ssh\] $v/test/fixed/ssh:fingerprint#, "SSH-type fingerprint secret missing";
matches $msg, qr#  \* \[random\] $v/test/fmt/sha512/default:random#, "Random-type secret missing";
matches $msg, qr#  \* \[random/formatted\] $v/test/fmt/sha512/default:random-crypt-sha512#, "Random-type formatted secret missing";

runs_ok "genesis secrets add us-east-sandbox --vault unit-tests";
for (@$rotated, @$fixed) {
  have_secret "$v/$_";
  $after{$_} = secret "$v/$_";
}
for my $path (@$rotated, @$fixed) {
  if (grep {$_ eq $path} @$removed) {
    isnt $before{$path}, $after{$path}, "$path should be recreated with a new value";
  } else {
    is $before{$path}, $after{$path}, "$path should be left unchanged";
  }
}

reprovision kit => 'asksecrets';
my $cmd = Expect->new();
$cmd->log_stdout(0);
$cmd->spawn("genesis new east-us-sandbox");
$v = "secret/east/us/sandbox/asksecrets";
expect_ok $cmd, ["Which Vault would you like to target.*\n.*> ", sub { $_[0]->send("unit-tests\n"); }];
expect_ok $cmd, ['password .*\[hidden\]:', sub { $_[0]->send("my-password\n");}];
expect_ok $cmd, ['password .*\[confirm\]:',  sub { $_[0]->send("my-password\n");}];
expect_ok $cmd, ["\\(Enter <CTRL-D> to end\\)", sub {
	$_[0]->send("this\nis\nmulti\nline\ndata\n\x4");
}];
expect_exit $cmd, 0, "New environment with prompted secret succeeded";
have_secret "$v/admin:password";
is secret("$v/admin:password"), "my-password", "Admin password was stored properly";
have_secret "$v/cert:pem";
is secret("$v/cert:pem"), <<EOF, "Multi-line secret was stored properly";
this
is
multi
line
data
EOF

reprovision kit => "certificates";

$cmd = Expect->new();
$cmd->log_stdout(0);
$cmd->spawn("genesis new west-us-sandbox");
$v = "secret/west/us/sandbox/certificates";
expect_ok $cmd, [ "Which Vault would you like to target.*\n.*>", sub { $_[0]->send("unit-tests\n"); }];
expect_ok $cmd, [ "Generate all the certificates?", sub { $_[0]->send("yes\n"); }];
expect_ok $cmd, [ "What is your base domain?", sub { $_[0]->send("cf.example.com\n"); }];
expect_exit $cmd, 0, "genesis creates a new environment and auto-generates certificates";

have_secret "$v/auto-generated-certs-a/ca:certificate";
my $x509 = qx(safe get $v/auto-generated-certs-a/ca:certificate | openssl x509 -inform pem -text);
like $x509, qr/Issuer: CN=ca.auto-generated-certs-a/m, "CA cert is self-signed";
like $x509, qr/Subject: CN=ca.auto-generated-certs-a/m, "CA cert is self-signed";

have_secret "$v/auto-generated-certs-a/server:certificate";
$x509 = qx(safe get $v/auto-generated-certs-a/server:certificate | openssl x509 -inform pem -text);
like $x509, qr/Issuer: CN=ca\.auto-generated-certs-a/m, "server cert is signed by the CA";
like $x509, qr/Subject: CN=server\.example\.com/m, "server cert has correct CN";
like $x509, qr/DNS:$_/m, "server cert has SAN for $_"
  for qw/server\.example\.com \*\.server\.example\.com \*\.system\.cf\.example\.com/;
like $x509, qr/IP Address:10\.10\.10\.10/m, "server cert has an IP SAN for 10.10.10.10";

have_secret "$v/auto-generated-certs-a/server:key";
like secret("$v/auto-generated-certs-a/server:key"), qr/----BEGIN RSA PRIVATE KEY----/,
	"server private key looks like an rsa private key";

have_secret "$v/auto-generated-certs-b/ca:certificate";
my $ca_a = secret "$v/auto-generated-certs-a/ca:certificate";
my $ca_b = secret "$v/auto-generated-certs-b/ca:certificate";
isnt $ca_a, $ca_b, "CA for auto-generated-certs-a is different from that for auto-generated-certs-b";

have_secret "$v/auto-generated-certs-b/server:certificate";
$x509 = qx(safe get $v/auto-generated-certs-b/server:certificate | openssl x509 -inform pem -text);
like $x509, qr/Issuer: CN=ca\.auto-generated-certs-b/m, "server B cert is signed by the CA from auto-generated-certs-b";

$cmd = Expect->new();
$cmd->log_stdout(0);
$cmd->spawn("genesis new north-us-sandbox");
$v = "secret/north/us/sandbox/certificates";
expect_ok $cmd, [ "Which Vault would you like to target.*\n.*> ", sub { $_[0]->send("unit-tests\n"); }];
expect_ok $cmd, [ "Generate all the certificates?", sub { $_[0]->send("no\n"); }];
expect_ok $cmd, [ "What is your base domain?", sub { $_[0]->send("cf.example.com\n"); }];
expect_exit $cmd, 0, "genesis creates a new environment and doesn't create new certificates from ignored submodules";
no_secret "$v/auto-generated-certs-b/ca";
no_secret "$v/auto-generated-certs-b/server";

$v = "secret/west/us/sandbox/certificates";
runs_ok "safe delete -Rf $v", "clean up certs for rotation testing";
no_secret "$v/auto-generated-certs-a/ca:certificate";
($pass,$rc,$msg) = run_fails "genesis secrets check west-us-sandbox --vault unit-tests", 1;
matches $msg, qr#Missing 16 credentials or certificates:#, "Correct number of secrets reported missing";
matches $msg, qr#  \* \[CA certificate] $v/auto-generated-certs-a/ca:certificate#,  "CA cert certificate missing";
matches $msg, qr#  \* \[CA certificate] $v/auto-generated-certs-a/ca:combined#,  "CA cert combined missing";
matches $msg, qr#  \* \[CA certificate] $v/auto-generated-certs-a/ca:crl#,  "CA cert crl missing";
matches $msg, qr#  \* \[CA certificate] $v/auto-generated-certs-a/ca:key#,  "CA cert key missing";
matches $msg, qr#  \* \[CA certificate] $v/auto-generated-certs-a/ca:serial#,  "CA cert serial missing";
matches $msg, qr#  \* \[certificate] $v/auto-generated-certs-a/server:certificate#, "Cert certificate missing";
matches $msg, qr#  \* \[certificate] $v/auto-generated-certs-a/server:combined#, "Cert combined missing";
matches $msg, qr#  \* \[certificate] $v/auto-generated-certs-a/server:key#, "Cert key missing";
matches $msg, qr#  \* \[CA certificate] $v/auto-generated-certs-b/ca:certificate#,  "CA cert certificate missing";
matches $msg, qr#  \* \[CA certificate] $v/auto-generated-certs-b/ca:combined#,  "CA cert combined missing";
matches $msg, qr#  \* \[CA certificate] $v/auto-generated-certs-b/ca:crl#,  "CA cert crl missing";
matches $msg, qr#  \* \[CA certificate] $v/auto-generated-certs-b/ca:key#,  "CA cert key missing";
matches $msg, qr#  \* \[CA certificate] $v/auto-generated-certs-b/ca:serial#,  "CA cert serial missing";
matches $msg, qr#  \* \[certificate] $v/auto-generated-certs-b/server:certificate#, "Cert certificate missing";
matches $msg, qr#  \* \[certificate] $v/auto-generated-certs-b/server:combined#, "Cert combined missing";
matches $msg, qr#  \* \[certificate] $v/auto-generated-certs-b/server:key#, "Cert key missing";

runs_ok "genesis secrets rotate --vault unit-tests west-us-sandbox", "genesis secrets creates our certs";
have_secret "$v/auto-generated-certs-a/server:certificate";
my $cert = secret "$v/auto-generated-certs-a/server:certificate";
have_secret "$v/auto-generated-certs-a/ca:certificate";
my $ca = secret "$v/auto-generated-certs-a/ca:certificate";

runs_ok "genesis secrets rotate --vault unit-tests west-us-sandbox", "genesis secrets doesn't rotate the CA";
have_secret "$v/auto-generated-certs-a/ca:certificate";
my $new_ca = secret "$v/auto-generated-certs-a/ca:certificate";
is $ca, $new_ca, "CA cert doesnt change under normal secret rotation";

runs_ok "genesis secrets add --vault unit-tests west-us-sandbox", "genesis secrets --missing-only doesn't rotate the CA";
have_secret "$v/auto-generated-certs-a/ca:certificate";
$new_ca = secret "$v/auto-generated-certs-a/ca:certificate";
is $ca, $new_ca, "CA cert doesnt change under normal secret rotation";

$cert = secret "$v/auto-generated-certs-a/server:certificate";
runs_ok "genesis secrets add --vault unit-tests west-us-sandbox", "genesis secrets --missing-only doesn't rotate regular certs";
have_secret "$v/auto-generated-certs-a/server:certificate";
my $new_cert = secret "$v/auto-generated-certs-a/server:certificate";
is $cert, $new_cert, "Certificates do not change if existing";

runs_ok "genesis secrets rotate --vault unit-tests west-us-sandbox", "genesis secrets rotates regular certs";
have_secret "$v/auto-generated-certs-a/server:certificate";
$new_cert = secret "$v/auto-generated-certs-a/server:certificate";
isnt $cert, $new_cert, "Certificates are rotated normally";

$cert = secret "$v/auto-generated-certs-a/server:certificate";
runs_ok "genesis secrets rotate --force-rotate-all --vault unit-tests west-us-sandbox", "genesis secrets --force-rotate-all regenerates CA certs";
have_secret "$v/auto-generated-certs-a/ca:certificate";
$new_ca = secret "$v/auto-generated-certs-a/ca:certificate";
isnt $ca, $new_ca, "CA certificate changes under force-rotation";
$new_cert = secret "$v/auto-generated-certs-a/server:certificate";
isnt $cert, $new_cert, "Certificates are rotated when forced.";

$cert = secret "$v/auto-generated-certs-a/server:certificate";
runs_ok "genesis secrets rotate -f --vault unit-tests west-us-sandbox", "genesis secrets -f regenerates CA certs";
have_secret "$v/auto-generated-certs-a/ca:certificate";
$new_ca = secret "$v/auto-generated-certs-a/ca:certificate";
isnt $ca, $new_ca, "CA certificate changes under force-rotation";
$new_cert = secret "$v/auto-generated-certs-a/server:certificate";
isnt $cert, $new_cert, "Certificates are rotated when forced.";

chdir $TOPDIR;
teardown_vault;
done_testing;
