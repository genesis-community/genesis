#!/perl

use strict;
use warnings;

use Expect;
use Test::Differences;
use lib 't';
use helper;

bosh2_cli_ok;

my $dir = workdir 'subkit-hook-deployments';
chdir $dir;

reprovision kit => "subkit-hooks";

sub subkit_hook_ok {
	my ($env, $rc, $msg) = @_;
	my $cmd = Expect->new();
	$cmd->log_stdout(0);
	$cmd->spawn("genesis new $env --no-secrets");
	expect_ok $cmd, ["Install OpenVPN?", sub { $_[0]->send("yes\n"); }];
	expect_exit $cmd, $rc, $msg;
}

sub new_hook {
	my ($file, $content) = @_;
	open my $fh, ">", $file or fail "Couldn't write to $file: $!";
	print $fh $content;
	close $fh;
}

subkit_hook_ok "hook-fails", 2, "Subkit hook fails if it returns a bad subkit";
no_env "hook-fails";

new_hook "dev/hooks/subkit", <<EOF;
#!/bin/bash
echo ""
echo "openvpn"
echo ""
echo ""
echo "toolbelt"
echo ""
echo ""
EOF
subkit_hook_ok "airy-subkit", 0, "Subkit hook ignores blank lines";
is get_file("airy.yml"), <<EOF, "org file has correct subkits listed when hook echos blank lines";
---
kit:
  name:     dev
  version:  latest
  features:
  - openvpn
  - toolbelt
EOF
is get_file("airy-subkit.yml"), <<EOF, "env file is correct when hook echos blank lines";
---
params:
  env:   airy-subkit
  vault: airy/subkit/subkit-hooks
EOF

new_hook "dev/hooks/subkit", <<EOF;
#!/bin/bash
exit 0
EOF
subkit_hook_ok "no-subkits", 0, "Subkit hooks can override subkit selection";
is get_file("no.yml"), <<EOF, "env file has no subkits listed";
---
kit:
  name:     dev
  version:  latest
  features: []
EOF
is get_file("no-subkits.yml"), <<EOF, "env file has no subkits listed";
---
params:
  env:   no-subkits
  vault: no/subkits/subkit-hooks
EOF

new_hook "dev/hooks/subkit", <<EOF;
#!/bin/bash
echo "openvpn"
echo "toolbelt"
EOF
subkit_hook_ok "good-subkit", 0, "Subkit hook can add in additional subkits not listed in kit.yml";
is get_file("good.yml"), <<EOF, "env file has correct subkits listed";
---
kit:
  name:     dev
  version:  latest
  features:
  - openvpn
  - toolbelt
EOF
is get_file("good-subkit.yml"), <<EOF, "env file has correct subkits listed";
---
params:
  env:   good-subkit
  vault: good/subkit/subkit-hooks
EOF

# -- param hook testing --
$dir = workdir 'paramhook-deployments';
chdir $dir;

reprovision kit => 'param-hooks';
rename "dev/hooks/params", "dev/hooks/params.bak";
runs_ok "genesis new no-additional-questions --no-secrets", "setup succeeds when no param hook exists";
is get_file("no.yml"), <<EOF, "environment yaml has original params when no hook present";
---
kit:
  name:     dev
  version:  latest
  features: []
EOF
is get_file("no-additional-questions.yml"), <<EOF, "environment yaml has original params when no hook present";
---
params:
  env:   no-additional-questions
  vault: no/additional/questions/param-hooks

  # This is your base domain
  #base_domain: bosh-lite.com
EOF
rename "dev/hooks/params.bak", "dev/hooks/params";

$ENV{HOOK_OUTPUT} = "echo '{}'";
$ENV{HOOK_EXIT} = 0;
chmod 0644, "dev/hooks/params";
run_fails "genesis new unexecutable-param-hook --no-secrets", 13, "Setup fails when param hook can't exec";
no_env "unexecutable-param-hook";
chmod 0755, "dev/hooks/params";

$ENV{HOOK_EXIT} = 4;
run_fails "genesis new failing-param-hook --no-secrets", undef, "Setup fails when param hook fails";
no_env "failing-param-hook";

$ENV{HOOK_EXIT} = 0;
$ENV{HOOK_OUTPUT} = "echo '}{'";
run_fails "genesis new bad-output-hook --no-secrets", 255, "Setup fails when param hook output is bad";
no_env "bad-output-hook";

$ENV{HOOK_OUTPUT} = "jq '.[1].comment = \"comment\" | .[1].values = [{ \"new_param\" : [{ \"message\":\"hi there\"},{\"message\":\"byebye\"}]}]' < \$1";
runs_ok "genesis new params-hook-succeeds --no-secrets", "Setup succeeds when param hook succeeds";
is get_file("params.yml"), <<EOF, "environment yaml has updated params";
---
kit:
  name:     dev
  version:  latest
  features: []
EOF
is get_file("params-hook-succeeds.yml"), <<EOF, "environment yaml has updated params";
---
params:
  env:   params-hook-succeeds
  vault: params/hook/succeeds/param-hooks

  # This is your base domain
  #base_domain: bosh-lite.com

  # comment
  new_param:
  - message: hi there
  - message: byebye
EOF

# Test combination of subkit and param hooks
reprovision kit => 'more-hooks', compiled => 1; # use a compiled kit to verify we extract param helpers

my $cmd = Expect->new();
my $env = "inspect-this";
$cmd->log_stdout(0);
$cmd->spawn("genesis new $env --no-secrets");
expect_ok $cmd, ["Install OpenVPN?", sub { $_[0]->send("yes\n"); }];
expect_ok $cmd, ["What is the temp dir\?", sub { $_[0]->send("$dir\n"); }];
expect_ok $cmd, ["You must type 'fun'", sub { $_[0]->send("'fun'\n"); }];
expect_ok $cmd, ["Please state your purpose: ", sub { $_[0]->send("\n"); }];
expect_ok $cmd, ["Please state your purpose: ", sub { $_[0]->send("be awesome\n"); }];

expect_exit $cmd, 0, "Creating new env with kit using subkit and param hooks";

eq_or_diff get_file("params.out"), <<EOF, "Contains the expected diagnostic output";
Environment: inspect-this

Subkits:
  - mandatory
  - openvpn

Input:
[
  {
    "comment": "Need to provide a tempdir for output",
    "default": 0,
    "example": null,
    "values": [
      {
        "tempdir": "$dir"
      }
    ]
  },
  {
    "comment": "This will get asked even if not specified",
    "default": 0,
    "example": null,
    "values": [
      {
        "mandatory_fun": "\'fun\'"
      }
    ]
  }
]
EOF

eq_or_diff get_file((split('-',$env))[0].".yml"), <<EOF, "New environment file contains correct data";
---
kit:
  name:     more-hooks
  version:  1.0.0
  features:
  - mandatory
  - openvpn
EOF
eq_or_diff get_file("$env.yml"), <<EOF, "New environment file contains correct data";
---
params:
  env:   inspect-this
  vault: inspect/this/more-hooks

  # Need to provide a tempdir for output
  tempdir: $dir

  # This will get asked even if not specified
  mandatory_fun: \'\'\'fun\'\'\'

  # this was programatically included
  rules:
  - protect humans
  - obey humans
  - protect self
  - be awesome
EOF


chdir $TOPDIR;
done_testing;
