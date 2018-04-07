#!perl
use strict;
use warnings;

use Expect;
use Test::Differences;
use lib 't';
use helper;

subtest 'params-asking skips' => sub { plan skip_all => 'params-asking is broke';
bosh2_cli_ok;

# EXPECT DEBUGGING
my $log_expect_stdout=$ENV{SHOW_EXPECT_OUTPUT}||0;

my $dir = workdir 'paramtest-deployments';
chdir $dir;

reprovision kit => 'ask-params';

my $cmd = Expect->new();
$cmd->log_stdout($log_expect_stdout);
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
	"What's your life story\\? \\(Enter <CTRL-D> to end\\\)[\r\n]{1,2}---------------------------------------------", sub {
		$_[0]->send("this\nis\nmulti\nline\ndata\n\x4");
	}
];

expect_ok "first blog entry", $cmd, [
	"Fill in your blog posts \\(leave entry empty to end\\\)[\r\n]{2,4}1st entry \\(Enter <CTRL-D> to end\\\)[\r\n]{1,2}---------------------------------[\r\n]{1,2}", sub {
		$_[0]->send("A programmer started to cuss\nCos getting to sleep was a fuss\nAs he lay in his bed, going round in his head\nwas while (!asleep) sheep++\n\x4")
	}
];
expect_ok "second blog entry", $cmd, [
	"2nd entry \\(Enter <CTRL-D> to end\\\)[\r\n]{1,2}---------------------------------[\r\n]{1,2}", sub {
		$_[0]->send("\x4")
	}
];
expect_ok "second blog entry - retry", $cmd, [
	"ERROR:.* Insufficient items provided - at least 2 required.[\r\n]{2,4}2nd entry \\(Enter <CTRL-D> to end\\\)[\r\n]{1,2}---------------------------------[\r\n]{1,2}", sub {
		$_[0]->send("A programmer's wife tells him: \"Run to the store and pick up a loaf of bread. If they have eggs, get a dozen.\"\nThe programmer comes home with 12 loaves of bread.\n\x4")
	}
];
expect_ok "third blog entry", $cmd, [
	"3rd entry \\(Enter <CTRL-D> to end\\\)[\r\n]{1,2}---------------------------------[\r\n]{1,2}", sub {
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
expect_ok "completed list, enter an invalid match", $cmd, [
  "6th language >", sub {
    print STDERR "Exit status: " . ($cmd->exitstatus() >> 8);
    fail "got prompted for a 6th language, but should have stopped after 5";
  }], [
  "Give me a number[\r\n]{1,2}>",  sub {
    $_[0]->send("3\n");
  }
];
expect_ok "a different number that isn't verboten", $cmd, [
  "Invalid:.* Cannot be one of 1, 3, 5, 7[\r\n]{1,2}>", sub {
    $_[0]->send("-5\n");
  }
];
expect_ok "exclusionary regex pattern - fail", $cmd,[
  "Invalid:.* Cannot be one of 1, 3, 5, 7[\r\n]{1,2}>", sub {
    fail "-5 got rejected even though it isn't 1,3,5 or 7";;
  }], [
  "An inflatable spherical object[\r\n]{1,2}>", sub {
    $_[0]->send("balloon\n");
  }
];

expect_ok "exclusionary regex pattern - pass", $cmd, [
  "Invalid:.* Matches exclusionary pattern[\r\n]{1,2}>", sub {
    $_[0]->send("tire\n");
  }
];

expect_ok "range input - fail", $cmd,[
  "Invalid:.* Matches exclusionary pattern[\r\n]{1,2}>", sub {
    fail "'tire' got rejected even though it doesn't match pattern";;
  }], [
  "Adjust treble baseline[\r\n]{1,2}>", sub {
    $_[0]->send("101\n");
  }
];

expect_ok "range input fail - pass", $cmd, [
  "Invalid:.* expected to be between -5 and 5[\r\n]{1,2}>", sub {
    $_[0]->send("2\n");
  }
];

expect_ok "range input - unbounded max - fail", $cmd,[
  "Invalid:.* expected to be between -5 and 5[\r\n]{1,2}>", sub {
    fail "2 is between -5 and 5, but wasn't accepted";;
  }], [
  "What is your age[\r\n]{1,2}>", sub {
    $_[0]->send("18\n");
  }
];

expect_ok "range input unbounded max - pass", $cmd, [
  "Invalid:.* must be at least 21[\r\n]{1,2}>", sub {
    $_[0]->send("111\n");
  }
];

expect_ok "range input - unbounded max - fail (negative)", $cmd,[
  "Invalid:.* must be at least 21[\r\n]{1,2}>", sub {
    fail "111 is greater than 21, but wasn't accepted";;
  }], [
  "What is your real age[\r\n]{1,2}>", sub {
    $_[0]->send("-22\n");
  }
];

expect_ok "range input unbounded max - pass (on boundry)", $cmd, [
  "Invalid:.* must be at least 18[\r\n]{1,2}>", sub {
    $_[0]->send("18\n");
  }
];


expect_ok "colour choices", $cmd,[
  "Invalid:.* must be at least 18[\r\n]{1,2}>", sub {
    fail "18 is the minumum, but wasn't accepted";;
  }], [
  "Lets mix some colors[\r\n]{1,2}Select between 2 and 3 colors[\r\n]{1,2}  1\\) red[\r\n]{1,2}  2\\) orange[\r\n]{1,2}  3\\) yellow[\r\n]{1,2}  4\\) green[\r\n]{1,2}  5\\) blue[\r\n]{1,2}  6\\) indigo[\r\n]{1,2}  7\\) violet[\r\n]{2,4}Make your selections \\(leave choice empty to end\\):[\r\n]{2,2}1st choice >", sub {
    $_[0]->send("5\n");
  }
];

expect_ok "colour choices - abort early", $cmd, [
  "blue[^\r\n]*[\r\n]{1,2}2nd choice >", sub {
    $_[0]->send("\n");
  }
];
expect_ok "colour choices - i really like blue", $cmd, [
  "Insufficient items provided - at least 2 required.[\r\n]{1,2}2nd choice >", sub {
    $_[0]->send("5\n");
  }
];
expect_ok "colour choices - make some green", $cmd, [
  "blue already selected - choose another value.[\r\n]{1,2}2nd choice >", sub {
    $_[0]->send("3\n");
  }
];

expect_ok "colour choices - done", $cmd, [
  "yellow[^\r\n]*[\r\n]{1,2}3rd choice >", sub {
    $_[0]->send("\n");
  }
];

expect_ok "paired programming partners - mystery stranger", $cmd,[
  "Insufficient items provided - at least 2 required[\r\n]{1,2}3rd choice >", sub {
    fail "Entered 2 choices, but it wants more";
  }], [
  "Select your partner[\r\n]{1,2}  1\\) Julia Breiner[\r\n]{1,2}  2\\) Intan Jans[\r\n]{1,2}  3\\) Irma D. Spears[\r\n]{1,2}  4\\) Sudhir Lykke[\r\n]{2,4}Select choice >", sub {
    $_[0]->send("Joe\n");
  }
];

expect_ok "paired-programming partners - Sudhir", $cmd, [
  "enter a number between 1 and 4[\r\n]{1,2}Select choice >", sub {
    $_[0]->send("4\n");
  }
];
expect_ok "paired programming partners - got back fill", $cmd, [
  "Sudhir Lykke[^\r\n]*[\r\n]{1,2}", sub {
    1;
  }
];

expect_ok "choice use default", $cmd, [
  "Ice Cream Choices:[\r\n]{1,2}  1\\) chocolate [^\r\n]*\\(default\\)[^\r\n]*[\r\n]{1,2}  2\\) vanilla[\r\n]{1,2}  3\\) strawberry[\r\n]{2,4}Select choice >", sub {
    $_[0]->send("\n");
  }
];
expect_ok "choice using default - got default", $cmd, [
  "chocolate[^\r\n]*[\r\n]{1,2}", sub {
    1;
  }
];

expect_ok "choice not use default", $cmd, [
  "Pie Choices:[\r\n]{1,2}  1\\) chocolate cream[\r\n]{1,2}  2\\) apple [^\r\n]*\\(default\\)[^\r\n]*[\r\n]{1,2}  3\\) pumpkin[\r\n]{2,4}Select choice >", sub {
    $_[0]->send("3\n");
  }
];
expect_ok "choice not using default - got specified value", $cmd, [
  "pumpkin[^\r\n]*[\r\n]{1,2}", sub {
    1;
  }
];

expect_ok "URL parsing - simple", $cmd, [
  "URL #1[\r\n]{1,2}>", sub {
    $_[0]->send("http://example.com\n");
  }
];
expect_ok "URL parsing - with port", $cmd, [
  "http://example.com is not a valid URL[\r\n]{1,2}>", sub {
    fail "Valid url not correctly identified";
  }], [
  "URL #2[\r\n]{1,2}>", sub {
    $_[0]->send("http://example.com:3000\n");
  }
];
expect_ok "URL parsing - secure with query pramas", $cmd, [
  "http://example.com:3000 is not a valid URL[\r\n]{1,2}>", sub {
    fail "Valid url not correctly identified";
  }], [
  "URL #3[\r\n]{1,2}>", sub {
    $_[0]->send("https://client.mybank.com?account=direstraights&pw=Money+for+nothin\%27+chicks+for+free\n");
  }
];
expect_ok "URL parsing - file", $cmd, [
  "https://client.mybank.com?account=direstraights&pw=Money+for+nothin\%27+chicks+for+free is not a valid URL[\r\n]{1,2}>", sub {
    fail "Valid url not correctly identified";
  }], [
  "URL #4[\r\n]{1,2}>", sub {
    $_[0]->send("file:///etc/passwd\n");
  }
];
expect_ok "URL parsing - full", $cmd, [
  "file:///etc/passwd is not a valid URL[\r\n]{1,2}>", sub {
    fail "Valid url not correctly identified";
  }], [
  "URL #5[\r\n]{1,2}>", sub {
    $_[0]->send("https://bob:mypass\@example.com:1234/files/1/description?lang=en&fmt=json#the-good-stuff\n");
  }
];
expect_ok "URL parsing - bad url check 1 - no protocol", $cmd, [
  "https://bob:mypass\@example.com:1234/files/1/description?lang=en&fmt=json#the-good-stuff is not a valid URL[\r\n]{1,2}>", sub {
    fail "Valid url not correctly identified";
  }], [
  "URL #6[\r\n]{1,2}>", sub {
    $_[0]->send("this.is.it\n");
  }
];

expect_ok "URL parsing - bad url check 2 - ftp not allowed", $cmd, [
  "this.is.it is not a valid URL[\r\n]{1,2}>", sub {
    $_[0]->send("ftp://user:pass\@ftp.example.com\n");
  }
];
expect_ok "URL parsing - bad url check 2 - ftp not allowed", $cmd, [
  "ftp://user:pass\@ftp.example.com is not a valid URL[\r\n]{1,2}>", sub {
    $_[0]->send("ftp://user:pass\@ftp.example.com\n");
  }
];
expect_ok "URL parsing - bad url check 3 - invalid characters", $cmd, [
  "ftp://user:pass\@ftp.example.com is not a valid URL[\r\n]{1,2}>", sub {
    $_[0]->send("https://my.dev.local:5555/endpoint?badquery='this is not allowed'\n");
  }
];
expect_ok "URL parsing - finish up", $cmd, [
  "https://my.dev.local:5555/endpoint\\?badquery='this is not allowed' is not a valid URL[\r\n]{1,2}>", sub {
    $_[0]->send("https://github.com/starkandwayne/genesis/blob/master/t/param-asking.t#L345\n");
  }
];


expect_ok "IP parsing - initial prompt", $cmd, [
  "IP Address[\r\n]{1,2}>", sub {
    $_[0]->send("mysite.example.com\n");
  }
];
expect_ok "IP parsing - used domain name", $cmd, [
  "Specify the path", sub {
    fail "Invalid IP address not correctly identified: used domain name";
  }], [
  "mysite.example.com is not a valid IPv4 address[\r\n]{1,2}>", sub {
    $_[0]->send("123.045.067.008\n");
  }
];
expect_ok "IP parsing - used leading zeros", $cmd, [
  "Specify the path", sub {
    fail "Invalid IP address not correctly identified: used leading zeros";
  }], [
  "123.045.067.008 is not a valid IPv4 address: octets cannot be zero-padded[\r\n]{1,2}>", sub {
    $_[0]->send("123.456.789.10\n");
  }
];
expect_ok "IP parsing - octets too big", $cmd, [
  "Specify the path", sub {
    fail "Invalid IP address not correctly identified: octets too big";
  }], [
  "123.456.789.10 is not a valid IPv4 address[\r\n]{1,2}>", sub {
    $_[0]->send("123.45.67\n");
  }
];
expect_ok "IP parsing - not enough octets", $cmd, [
  "Specify the path", sub {
    fail "Invalid IP address not correctly identified: not enough octets";
  }], [
  "123.45.67 is not a valid IPv4 address[\r\n]{1,2}>", sub {
    $_[0]->send("123.4.5.6.78\n");
  }
];
expect_ok "IP parsing - too many octets", $cmd, [
  "Specify the path", sub {
    fail "Invalid IP address not correctly identified: too many octets";
  }], [
  "123.4.5.6.78 is not a valid IPv4 address[\r\n]{1,2}>", sub {
    $_[0]->send("123.4.5.67\n");
  }
];
expect_ok "IP parsing - loopback", $cmd, [
  "Loopback IP Address[\r\n]{1,2}>", sub {
    $_[0]->send("127.0.0.1\n");
  }
];
expect_ok "IP parsing - unspecified ip address ", $cmd, [
  "Listening IP Address[\r\n]{1,2}>", sub {
    $_[0]->send("0.0.0.0\n");
  }
];
expect_ok "IP parsing - bounds checking ", $cmd, [
  "Network Mask[\r\n]{1,2}>", sub {
    $_[0]->send("10.0.255.255\n");
  }
];

expect_ok "Vault paths with --no-secrets option", $cmd, [
  "Warning:.* Cannot validate vault paths when --no-secrets option specified[\r\n]{1,2}Specify the path[\r\n]{1,2}>", sub {
    $_[0]->send("/secret/this/path/does/not/exist\n");
  }
];
expect_ok "Vault paths and key prompt with --no-secrets option", $cmd, [
  "not found in vault", sub {
    fail "got vault validation failure but --no-secrets was specified";
  }], [
  "Warning:.* Cannot validate vault paths when --no-secrets option specified[\r\n]{1,2}Specify the path with key[\r\n]{1,2}>", sub {
    $_[0]->send("/secret/this/path/does/not/exist\n");
  }
];

expect_ok "Vault path and key without key, --no-secrets option", $cmd, [
  "not found in vault", sub {
    fail "got vault validation failure but --no-secrets was specified";
  }], [
  "Skipping generation", sub {
    fail "Did not get error when key was missing";
  }], [
  "\\/secret\\/this\\/path\\/does\\/not\\/exist is missing a key - expecting secret\\/<path>:<key>[\r\n]{1,2}>", sub {
    $_[0]->send("/secret/this/path/does/not/exist:password\n");
  }
];


expect_ok "Finished, --no-secrets option", $cmd, [
  "not found in vault", sub {
    fail "got vault validation failure but --no-secrets was specified";
  }], [
  "Skipping generation", sub {
    1;
  }], [
  '\/secret\/this\/path\/does\/not\/exist:password is missing a key - expecting secret\/<path>:<key>', sub {
    fail "Provided a key, but got a key missing error message";
  }
];

expect_exit $cmd, 0, "Creating a new environment with subkits exited successfully";
eq_or_diff get_file("with.yml"), <<EOF, "New environment file contains base + subkit params, comments, and examples";
---
kit:
  name:     dev
  version:  latest
  features:
  - subkit-params
EOF

eq_or_diff get_file("with-subkit.yml"), <<EOF, "New environment file contains base + subkit params, comments, and examples";
---
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

  # Type any number except 1, 3, 5 or 7
  not-in-list: -5

  # Don't use any words that have two consecutive identical letters
  not-a-match: tire

  # I need a number between -5 and 5
  in-a-range: 2

  # Super secure check to see if you're allowed to drink
  age: 111

  # Okay, now enter your REAL age
  real-age: 18

  # Lets mix some colors
  color-choices:
  - blue
  - yellow

  # Pairing on code is an important skill to develop
  pick-a-person: sudhir

  # What's your favorite flavour of icecream?
  pick-icecream-default: chocolate

  # What's your favorite pie?
  pick-pie-notdefault: pumpkin

  # Give me your favorite site's URL
  need-a-url: http://example.com

  # Give me your dev test URL with port
  need-a-url-and-port: http://example.com:3000

  # Give me your banks URL and login creds
  need-a-https-url-and-query-param: https://client.mybank.com?account=direstraights&pw=Money+for+nothin\%27+chicks+for+free

  # Give me your password file URL
  need-a-file-url: file:///etc/passwd

  # Give me your favorite site's URL
  need-a-full-url: https://bob:mypass\@example.com:1234/files/1/description?lang=en&fmt=json#the-good-stuff

  # Give me a bad URL (not that kind)
  test-bad-URL-handling: https://github.com/starkandwayne/genesis/blob/master/t/param-asking.t#L345

  # Need a url
  ipaddress: 123.4.5.67

  # Need your loopback IP address
  loopback-ipaddress: 127.0.0.1

  # Listen on what IP address
  listen-on-ip: 0.0.0.0

  # Internal network mask
  mask: 10.0.255.255

  # Need a vault path
  validity-vault_path: /secret/this/path/does/not/exist

  # Need a vault path with key
  validity-vault_path_and_key: /secret/this/path/does/not/exist:password
EOF

$cmd = Expect->new();
$cmd->log_stdout($log_expect_stdout);
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
expect_exit $cmd, 0, "Creating a new environment without subkits exited successfully";
eq_or_diff get_file("without.yml"), <<EOF, "New environment file contains base params, comments, and examples (no subkits)";
---
kit:
  name:     dev
  version:  latest
  features: []
EOF

eq_or_diff get_file("without-subkit.yml"), <<EOF, "New environment file contains base params, comments, and examples (no subkits)";
---
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
};
done_testing;
