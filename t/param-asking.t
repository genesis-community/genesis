#!perl
use strict;
use warnings;

use Expect;
use Test::Differences;
use lib 't';
use helper;

bosh_ruby_cli_ok;

my $dir = workdir 'paramtest-deployments';
chdir $dir;

reprovision kit => 'ask-params';

my $cmd = Expect->new();
$cmd->log_stdout(0);
$cmd->spawn("genesis new with-subkit --no-secrets");
expect_ok "extra questions subkit", $cmd, [
	'Should we ask additional questions?', sub {
		my $fh = shift;
		$fh->send("yes\n");
	}
];
expect_ok "setting cloud foundry base domain: empty", $cmd, [
	'What is the base domain of your Cloud Foundry?', sub {
		my $fh = shift;
		$fh->send("\n");
	}
];
expect_ok "setting cloud foundry base domain: value", $cmd, [
	'No default:.* you must specify a non-empty string', sub {
		my $fh = shift;
		$fh->send("cf.example.com\n");
	}
];
expect_ok "getting first user", $cmd, ['1st user >', sub {
		$_[0]->send("gfranks\n"); }];
expect_ok "getting second user", $cmd, ['2nd user >', sub {
		$_[0]->send("dbell\n"); }];
expect_ok "getting third user", $cmd, ['3rd user >', sub {
		$_[0]->send("jhunt\n"); }];
expect_ok "getting forth user", $cmd, ['4th user >', sub {
		$_[0]->send("tstark\n"); }];
expect_ok "getting fifth user", $cmd, ['5th user >', sub {
		$_[0]->send("\n"); }];

expect_ok $cmd, ["This shouldn't be asked?", sub {
		print STDERR "Exit status: " . ($cmd->exitstatus() >> 8);
		fail "--no-secrets enabled, but we were asked for a secret";
	}],
	["How many fish heads do you want?", sub {
		my $fh = shift;
		$fh->send("5\n");
}];
expect_ok "answer a question using default", $cmd, [
	"Are there rocks ahead\\? .*(default: If there are, we all be dead).*[\r\n]{1,2}> ", sub {
		$_[0]->send("\n");
	}
];
expect_ok "boolean with default of yes", $cmd, [
	"Is this a question\\?[\r\n]{1,2}\\[.*Y.*\\|n\\] > ", sub {
		$_[0]->send("\n");
	}
];
expect_ok "boolean with default of no", $cmd, [
	"Did you answer this\\?[\r\n]{1,2}\\[y\\|.*N.*\\] > ", sub {
		$_[0]->send("\n");
	}
];
expect_ok "answering a boolean with a default with an incorrect answer", $cmd, [
	"Would you\\?[\r\n]{1,2}\\[.*Y.*\\|n\\] > ", sub {
		$_[0]->send("never\n");
	}
];
expect_ok "...then with a different answer", $cmd, [
	"Invalid response:.* you must specify y, yes, true, n, no or false[\r\n]{1,2}\\[.*Y.*\\|n\\] > ", sub {
		$_[0]->send("no\n");
	}
];
expect_ok "answering a default-less boolean with a blank answer", $cmd, [
	"Flip a coin; is it heads\\?[\r\n]{1,2}\\[y\\|n\\] > ", sub {
		$_[0]->send("\n");
	}
];
expect_ok "...then with an actual answer", $cmd, [
	"Invalid response:.* you must specify y, yes, true, n, no or false[\r\n]{1,2}\\[y\\|n\\] > ", sub {
		$_[0]->send("yes\n");
	}
];


expect_ok "multi-line question", $cmd, [
	"What's your life story\\? \\(Enter <CTRL-D> to end\\)[\r\n]{1,2}---------------------------------------------", sub {
		$_[0]->send("this\nis\nmulti\nline\ndata\n\x4");
	}
];

expect_ok "first blog entry", $cmd, [
	"Fill in your blog posts \\(leave entry empty to end\\)[\r\n]{2,4}1st entry \\(Enter <CTRL-D> to end\\)[\r\n]{1,2}---------------------------------[\r\n]{1,2}", sub {
		$_[0]->send("A programmer started to cuss\nCos getting to sleep was a fuss\nAs he lay in his bed, going round in his head\nwas while (!asleep) sheep++\n\x4")
	}
];
expect_ok "second blog entry", $cmd, [
	"2nd entry \\(Enter <CTRL-D> to end\\)[\r\n]{1,2}---------------------------------[\r\n]{1,2}", sub {
		$_[0]->send("\x4")
	}
];
expect_ok "second blog entry - retry", $cmd, [
	"ERROR:.* Insufficient items provided - at least 2 required.[\r\n]{2,4}2nd entry \\(Enter <CTRL-D> to end\\)[\r\n]{1,2}---------------------------------[\r\n]{1,2}", sub {
		$_[0]->send("A programmer's wife tells him: \"Run to the store and pick up a loaf of bread. If they have eggs, get a dozen.\"\nThe programmer comes home with 12 loaves of bread.\n\x4")
	}
];
expect_ok "third blog entry", $cmd, [
	"3rd entry \\(Enter <CTRL-D> to end\\)[\r\n]{1,2}---------------------------------[\r\n]{1,2}", sub {
		$_[0]->send("\x4")
	}
];
expect_ok "Regex pattern validation - fail", $cmd, [
  "Specify ip/mask[\r\n]{1,2}>", sub {
    $_[0]->send("999.999.999.999/99\n");
  }
];
expect_ok "Regex pattern validation - pass", $cmd, [
  "Invalid:.* Does not match required pattern[\r\n]{1,2}>", sub {
    $_[0]->send("192.168.0.0/16\n")
  }
];
expect_ok "1st language", $cmd, [
  "1st language >", sub {
    $_[0]->send("ruby\n");
  }
];
expect_ok "2nd language -- will be invalid", $cmd, [
  "2nd language >", sub {
    $_[0]->send("python\n");
  }
];
expect_ok "2nd language after invalid one", $cmd, [
  "Invalid:.* Expecting one of c, lisp, ruby, perl, go[\r\n]{1,2}2nd language >", sub {
    $_[0]->send("perl\n");
  }
];
expect_ok "3rd language", $cmd, [
  "3rd language >", sub {
    $_[0]->send("c\n");
  }
];
expect_ok "4th language - premature end of list", $cmd, [
  "4th language >", sub {
    $_[0]->send("lisp\n");
  }
];
expect_ok "5th language", $cmd, [
  "5th language >", sub {
    $_[0]->send("\n");
  }
];
expect_ok "reprompt for 5th language", $cmd, [
  "ERROR:.* Insufficient items provided - at least 5 required.[\r\n]{1,2}5th language >", sub {
    $_[0]->send("go\n");
  }
];
expect_ok "completed list, next question", $cmd, [
  "6th language >", sub {
    print STDERR "Exit status: " . ($cmd->exitstatus() >> 8);
    fail "got prompted for a 6th language, but should have stopped after 5";
  }], [
  "Warning:.* Cannot validate vault path when --no-secrets option specified[\r\n]{1,2}Specify the path[\r\n]{1,2}>", sub {
    $_[0]->send("/secret/this/path/does/not/exist\n");
  }
];
expect_ok "", $cmd, [
  "not found in vault", sub {
    fail "got vault validation failure but --no-secrets was specified";
  }], [
  "Skipping generation", sub {
    1
  }
];

$cmd->soft_close();
is $cmd->exitstatus() >> 8, 0, "Creating a new environment with subkits exited successfully";
eq_or_diff get_file("with-subkit.yml"), <<EOF, "New environment file contains base + subkit params, comments, and examples";
---
kit:
  name:    dev
  version: latest
  subkits:
  - subkit-params

params:
  env:   with-subkit
  vault: with/subkit/ask-params

  # This is used to autocalculate many domain-based values of your Cloud Foundry.
  # Changing it will have widespread changes throughout the installation. If you change
  # this, make sure to audit the domains available in your system org, as well as
  # the shared domains.
  # (e.g. bosh-lite.com)
  base_domain: cf.example.com

  # Used to scale out the number of VMs performing various jobs
  #cell_instances: 3
  #router_instances: 2
  #nats_instances: 2

  # Default VM type for cell nodes
  #cell_vm_type: small

  # Enter a list of names. Anything will do
  allowed_users:
  - gfranks
  - dbell
  - jhunt
  - tstark

  # Specify the availability zones your deployment is spread across
  #availability_zones:
  #- z1
  #- z2
  #- z3

  # This value sets the port advertised for wss://doppler.<system_domain>
  #logger_port: 4443

  # This value refers to the number of fish heads you earned in apple school.
  # (e.g. FIVE)
  fish_heads: 5

  # That Vizzini, he can fuss
  fezzik_quote: If there are, we all be dead

  # Defaults to yes
  boolean-a: true

  # Defaults to no
  boolean-b: false

  # Defaults but answered.
  boolean-c: false

  # No defaults
  boolean-d: true

  # Enter a big paragraph here
  biography: |
    this
    is
    multi
    line
    data

  # You're an interesting person; tell us about your thoughts
  blog:
  - |
    A programmer started to cuss
    Cos getting to sleep was a fuss
    As he lay in his bed, going round in his head
    was while (!asleep) sheep++
  - |
    A programmer's wife tells him: "Run to the store and pick up a loaf of bread. If they have eggs, get a dozen."
    The programmer comes home with 12 loaves of bread.

  # The CIDR for your target network; pattern of #.#.#.#/#
  validity-regex: 192.168.0.0/16

  # Order these languages in order of preference: c, lisp, ruby, perl, go
  validity-list:
  - ruby
  - perl
  - c
  - lisp
  - go

  # Need a vault path
  validity-vault_path: /secret/this/path/does/not/exist
EOF

$cmd = Expect->new();
$cmd->log_stdout(1);
$cmd->spawn("genesis new without-subkit --no-secrets");
expect_ok $cmd, ['Should we ask additional questions', sub {
	my $fh = shift;
	$fh->send("no\n");
}];
expect_ok $cmd, ['What is the base domain of your Cloud Foundry?', sub {
	my $fh = shift;
	$fh->send("cf.example.com\n");
}];
expect_ok "getting first user", $cmd, ['1st user >', sub {
		$_[0]->send("gfranks\n"); }];
expect_ok "getting second user", $cmd, ['2nd user >', sub {
		$_[0]->send("dbell\n"); }];
expect_ok "getting third user", $cmd, ['3rd user >', sub {
		$_[0]->send("\n"); }];
$cmd->soft_close();
is $cmd->exitstatus() >> 8, 0, "Creating a new environment without subkits exited successfully";
eq_or_diff get_file("without-subkit.yml"), <<EOF, "New environment file contains base params, comments, and examples (no subkits)";
---
kit:
  name:    dev
  version: latest
  subkits: []

params:
  env:   without-subkit
  vault: without/subkit/ask-params

  # This is used to autocalculate many domain-based values of your Cloud Foundry.
  # Changing it will have widespread changes throughout the installation. If you change
  # this, make sure to audit the domains available in your system org, as well as
  # the shared domains.
  # (e.g. bosh-lite.com)
  base_domain: cf.example.com

  # Used to scale out the number of VMs performing various jobs
  #cell_instances: 3
  #router_instances: 2
  #nats_instances: 2

  # Default VM type for cell nodes
  #cell_vm_type: small

  # Enter a list of names. Anything will do
  allowed_users:
  - gfranks
  - dbell

  # Specify the availability zones your deployment is spread across
  #availability_zones:
  #- z1
  #- z2
  #- z3
EOF

chdir $TOPDIR;
done_testing;
