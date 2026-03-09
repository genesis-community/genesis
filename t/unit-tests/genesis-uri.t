#!/usr/bin/env perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;

use Test::More;

use_ok 'Genesis';

subtest 'uri parsing' => sub {
	for my $ok (qw(
		http://genesisproject.io
		https://genesisproject.io

		http://genesisproject.io:80
		https://genesisproject.io:443

		http://genesisproject.io/
		https://genesisproject.io/

		http://genesisproject.io/with/a/path
		https://genesisproject.io/with/a/path

		http://genesisproject.io:80/
		https://genesisproject.io:443////

		http://genesisproject.io:80/with/a/path
		https://genesisproject.io:443/with/a/path
		http://genesisproject.io:80/with/a/path/

		http://genesisproject.io/with/a/path?and=a&query=string
		https://genesisproject.io:443/with/a/path?and=a&query=string

		http://user:pass@genesisproject.io
	)) {
		ok is_valid_uri($ok), "'$ok' should be a valid URL";
	}

	# Invalid URIs
	for my $bad (qw(
		genesisproject.io
		ftp://genesisproject.io
		//genesisproject.io
	)) {
		ok !is_valid_uri($bad), "'$bad' should not be a valid URL";
	}
};

subtest 'parse_uri details' => sub {
	my %parts = parse_uri('https://user:pass@example.com:8443/path/to/resource?query=value#fragment');

	is $parts{scheme}, 'https', 'scheme parsed correctly';
	is $parts{user}, 'user', 'user parsed correctly';
	is $parts{password}, 'pass', 'password parsed correctly';
	is $parts{host}, 'example.com', 'host parsed correctly';
	is $parts{port}, '8443', 'port parsed correctly';
	is $parts{path}, '/path/to/resource', 'path parsed correctly';
	is $parts{query}, 'query=value', 'query parsed correctly';
	is $parts{fragment}, 'fragment', 'fragment parsed correctly';
};

subtest 'parse_uri without optional parts' => sub {
	my %parts = parse_uri('http://example.com/path');

	is $parts{scheme}, 'http', 'scheme parsed';
	is $parts{host}, 'example.com', 'host parsed';
	is $parts{path}, '/path', 'path parsed';
	ok !defined($parts{port}), 'port not present';
	ok !defined($parts{query}), 'query not present';
	ok !defined($parts{fragment}), 'fragment not present';
	ok !defined($parts{user}), 'user not present';
	ok !defined($parts{password}), 'password not present';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
