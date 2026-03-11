#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;
use Test::Exception;

$ENV{NOCOLOR}                = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{GENESIS_OUTPUT_LINES}   = 24;

use_ok 'Genesis::Term';

# Initialize Genesis::RC for codeblock tests
use Genesis::Config;
$Genesis::RC = Genesis::Config->new(undef, 0, {'ui' => {'colors' => {'code' => 'Wk'}}});

# ---------------------------------------------------------------------------
# build_markdown_paragraph
# ---------------------------------------------------------------------------
subtest 'build_markdown_paragraph - basic single paragraph' => sub {
	my $result = Genesis::Term::build_markdown_paragraph('Hello world', width => 40);
	like $result, qr/Hello world/, 'contains original text';
	unlike $result, qr/\n$/, 'no trailing newline';
};

subtest 'build_markdown_paragraph - wraps long line to width' => sub {
	my $text = 'one two three four five six seven eight nine ten eleven twelve';
	my $result = Genesis::Term::build_markdown_paragraph($text, width => 20);
	my @lines = split /\n/, $result;
	ok scalar(@lines) > 1, 'wraps onto multiple lines';
	for my $line (@lines) {
		ok length($line) <= 20, "line '$line' is within width 20";
	}
};

subtest 'build_markdown_paragraph - respects indent option' => sub {
	my $result = Genesis::Term::build_markdown_paragraph('hello world', width => 40, indent => 4);
	like $result, qr/^    hello world/, 'indent of 4 spaces applied';
};

subtest 'build_markdown_paragraph - respects prefix option' => sub {
	my $result = Genesis::Term::build_markdown_paragraph('hello world', width => 40, prefix => '>> ');
	like $result, qr/^>> hello world/, 'prefix applied to first line';
};

subtest 'build_markdown_paragraph - multiple sub-paragraphs joined with blank line' => sub {
	my $text = "First paragraph text.\n\nSecond paragraph text.";
	my $result = Genesis::Term::build_markdown_paragraph($text, width => 40);
	like $result, qr/First paragraph/, 'first sub-paragraph present';
	like $result, qr/Second paragraph/, 'second sub-paragraph present';
	like $result, qr/\n\n/, 'blank line separates sub-paragraphs';
};

subtest 'build_markdown_paragraph - uses terminal_width by default' => sub {
	my $result = Genesis::Term::build_markdown_paragraph('hello world');
	like $result, qr/hello world/, 'text rendered without width opt';
};

# ---------------------------------------------------------------------------
# build_markdown_blockquote
# ---------------------------------------------------------------------------
subtest 'build_markdown_blockquote - strips leading > marker' => sub {
	my $result = Genesis::Term::build_markdown_blockquote('> This is a quote', width => 40);
	unlike $result, qr/^>/, 'leading > stripped';
	like $result, qr/This is a quote/, 'content preserved';
};

subtest 'build_markdown_blockquote - default indent of 2' => sub {
	my $result = Genesis::Term::build_markdown_blockquote('> quoted text', width => 40);
	like $result, qr/^  /, 'default indent of 2 spaces applied';
};

subtest 'build_markdown_blockquote - custom indent option' => sub {
	my $result = Genesis::Term::build_markdown_blockquote('> quoted text', width => 40, indent => 4);
	like $result, qr/^    /, 'custom indent of 4 spaces applied';
};

subtest 'build_markdown_blockquote - strips > from continuation lines' => sub {
	my $block = "> line one\n> line two";
	my $result = Genesis::Term::build_markdown_blockquote($block, width => 40);
	unlike $result, qr/>/, '> markers stripped from all lines';
	like $result, qr/line one/, 'first line content present';
	like $result, qr/line two/, 'second line content present';
};

# ---------------------------------------------------------------------------
# build_markdown_codeblock
# ---------------------------------------------------------------------------
subtest 'build_markdown_codeblock - strips opening fence marker' => sub {
	my $block = "```\ncode here\n```";
	my $result = Genesis::Term::build_markdown_codeblock($block, width => 40);
	unlike $result, qr/```/, 'fence markers stripped';
	like decolorize($result), qr/code here/, 'code content present';
};

subtest 'build_markdown_codeblock - strips language-tagged fence' => sub {
	my $block = "```perl\nmy \$x = 1;\n```";
	my $result = Genesis::Term::build_markdown_codeblock($block, width => 40);
	unlike $result, qr/```/, 'fence markers stripped';
	like decolorize($result), qr/my \$x = 1;/, 'code content present';
};

subtest 'build_markdown_codeblock - multi-line code preserved' => sub {
	my $block = "```\nline one\nline two\nline three\n```";
	my $result = Genesis::Term::build_markdown_codeblock($block, width => 40);
	my $plain = decolorize($result);
	like $plain, qr/line one/, 'first line present';
	like $plain, qr/line two/, 'second line present';
	like $plain, qr/line three/, 'third line present';
};

subtest 'build_markdown_codeblock - truncates long lines with elipses' => sub {
	my $long = 'a' x 60;
	my $block = "```\n$long\n```";
	my $result = Genesis::Term::build_markdown_codeblock($block, width => 40);
	my $plain = decolorize($result);
	like $plain, qr/\.\.\./, 'long line truncated with ellipsis';
};

subtest 'build_markdown_codeblock - indent option adds leading spaces' => sub {
	my $block = "```\ncode\n```";
	my $result = Genesis::Term::build_markdown_codeblock($block, width => 40, indent => 4, padding => 0);
	like decolorize($result), qr/^    /, 'indent spaces prepended';
};

# ---------------------------------------------------------------------------
# build_markdown_table
# ---------------------------------------------------------------------------
subtest 'build_markdown_table - renders headers' => sub {
	my $table = "| Name | Value |\n|------|-------|\n| foo  | bar   |";
	my $result = build_markdown_table($table, width => 40);
	my $plain = decolorize($result);
	like $plain, qr/Name/, 'Name header present';
	like $plain, qr/Value/, 'Value header present';
};

subtest 'build_markdown_table - renders data rows' => sub {
	my $table = "| Name | Value |\n|------|-------|\n| foo  | bar   |";
	my $result = build_markdown_table($table, width => 40);
	my $plain = decolorize($result);
	like $plain, qr/foo/, 'data row cell foo present';
	like $plain, qr/bar/, 'data row cell bar present';
};

subtest 'build_markdown_table - has box-drawing border characters' => sub {
	my $table = "| Name | Value |\n|------|-------|\n| foo  | bar   |";
	my $result = build_markdown_table($table, width => 40);
	# With UTF8 enabled: box-drawing chars; without: ASCII + chars
	like $result, qr/[┏+]/, 'top border character present';
	like $result, qr/[┗+]/, 'bottom border character present';
};

subtest 'build_markdown_table - multiple data rows' => sub {
	my $table = "| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |";
	my $result = build_markdown_table($table, width => 40);
	my $plain = decolorize($result);
	like $plain, qr/1/, 'first data row present';
	like $plain, qr/3/, 'second data row present';
};

subtest 'build_markdown_table - right-aligned column from separator ---:' => sub {
	my $table = "| Left | Right |\n|:-----|------:|\n| aaa  | bbb   |";
	my $result = build_markdown_table($table, width => 40);
	my $plain = decolorize($result);
	like $plain, qr/Left/, 'left-aligned header present';
	like $plain, qr/Right/, 'right-aligned header present';
};

subtest 'build_markdown_table - center-aligned column from :---:' => sub {
	my $table = "| Center |\n|:------:|\n| mid    |";
	my $result = build_markdown_table($table, width => 40);
	my $plain = decolorize($result);
	like $plain, qr/Center/, 'center-aligned header present';
	like $plain, qr/mid/, 'center-aligned data present';
};

# ---------------------------------------------------------------------------
# build_markdown_list
# ---------------------------------------------------------------------------
subtest 'build_markdown_list - unordered list with - items' => sub {
	# Reset state by calling render_markdown with empty string
	render_markdown('');
	my $block = "- alpha\n- beta\n- gamma";
	my $result = Genesis::Term::build_markdown_list('list', $block, width => 40);
	my $plain = decolorize($result);
	like $plain, qr/alpha/, 'first item present';
	like $plain, qr/beta/, 'second item present';
	like $plain, qr/gamma/, 'third item present';
};

subtest 'build_markdown_list - unordered list with * items' => sub {
	render_markdown('');
	my $block = "* one\n* two";
	my $result = Genesis::Term::build_markdown_list('list', $block, width => 40);
	my $plain = decolorize($result);
	like $plain, qr/one/, 'first * item present';
	like $plain, qr/two/, 'second * item present';
};

subtest 'build_markdown_list - ordered/numbered list' => sub {
	render_markdown('');
	my $block = " 1. first\n 2. second\n 3. third";
	my $result = Genesis::Term::build_markdown_list('numbered_list', $block, width => 40);
	my $plain = decolorize($result);
	like $plain, qr/first/, 'first numbered item present';
	like $plain, qr/second/, 'second numbered item present';
	like $plain, qr/third/, 'third numbered item present';
	like $plain, qr/1\./, 'item number 1 present';
};

# ---------------------------------------------------------------------------
# process_markdown_block
# ---------------------------------------------------------------------------
subtest 'process_markdown_block - H1 header' => sub {
	my @links;
	my $result = process_markdown_block('# My Title', width => 40, links => \@links);
	my $plain = decolorize($result);
	like $plain, qr/My Title/, 'H1 header text present';
};

subtest 'process_markdown_block - H2 header' => sub {
	my @links;
	my $result = process_markdown_block('## Section Title', width => 40, links => \@links);
	my $plain = decolorize($result);
	like $plain, qr/Section Title/, 'H2 header text present';
	like $plain, qr/-+/, 'H2 has underline dashes';
};

subtest 'process_markdown_block - H3 header' => sub {
	my @links;
	my $result = process_markdown_block('### Sub Section', width => 40, links => \@links);
	my $plain = decolorize($result);
	like $plain, qr/Sub Section/, 'H3 header text present';
};

subtest 'process_markdown_block - H4 header' => sub {
	my @links;
	my $result = process_markdown_block('#### Detail', width => 40, links => \@links);
	my $plain = decolorize($result);
	like $plain, qr/Detail/, 'H4 header text present';
};

subtest 'process_markdown_block - paragraph passthrough' => sub {
	my @links;
	my $result = process_markdown_block('Simple paragraph text.', width => 40, links => \@links);
	like $result, qr/Simple paragraph text/, 'paragraph text passed through';
};

subtest 'process_markdown_block - code block via triple backtick' => sub {
	my @links;
	my $block = "```\nsome code\n```";
	my $result = process_markdown_block($block, width => 40, links => \@links);
	unlike $result, qr/```/, 'fence markers stripped';
	like decolorize($result), qr/some code/, 'code content present';
};

subtest 'process_markdown_block - blockquote via > prefix' => sub {
	my @links;
	my $result = process_markdown_block('> quoted text here', width => 40, links => \@links);
	unlike $result, qr/^>/, '> marker stripped';
	like $result, qr/quoted text here/, 'quote content present';
};

subtest 'process_markdown_block - unordered list detection' => sub {
	render_markdown('');
	my @links;
	my $result = process_markdown_block("- item one\n- item two", width => 40, links => \@links);
	my $plain = decolorize($result);
	like $plain, qr/item one/, 'first list item present';
	like $plain, qr/item two/, 'second list item present';
};

subtest 'process_markdown_block - table detection' => sub {
	render_markdown('');
	my @links;
	my $table = "| Col1 | Col2 |\n|------|------|\n| a    | b    |";
	my $result = process_markdown_block($table, width => 40, links => \@links);
	my $plain = decolorize($result);
	like $plain, qr/Col1/, 'table column header present';
	like $plain, qr/a/, 'table data present';
};

subtest 'process_markdown_block - inline bold with GENESIS_NOCOLOR unset' => sub {
	local $ENV{GENESIS_NOCOLOR};
	delete $ENV{GENESIS_NOCOLOR};
	my @links;
	my $result = process_markdown_block('Text **bold** more', width => 40, links => \@links);
	# With GENESIS_NOCOLOR unset, bold markers become ANSI sequences
	like $result, qr/bold/, 'bold text content present';
	like $result, qr/\e\[1;36m/, 'ANSI bold sequence injected';
};

subtest 'process_markdown_block - inline bold suppressed by GENESIS_NOCOLOR' => sub {
	local $ENV{GENESIS_NOCOLOR} = 1;
	my @links;
	my $result = process_markdown_block('Text **bold** more', width => 40, links => \@links);
	# With GENESIS_NOCOLOR=1, ** markers remain literal (no substitution)
	like $result, qr/\*\*bold\*\*/, 'GENESIS_NOCOLOR: ** markers kept literal';
};

subtest 'process_markdown_block - inline italic with GENESIS_NOCOLOR unset' => sub {
	local $ENV{GENESIS_NOCOLOR};
	delete $ENV{GENESIS_NOCOLOR};
	my @links;
	my $result = process_markdown_block('Text *italic* more', width => 40, links => \@links);
	like $result, qr/italic/, 'italic text content present';
	like $result, qr/\e\[3m/, 'ANSI italic sequence injected';
};

subtest 'process_markdown_block - inline strikethrough with GENESIS_NOCOLOR unset' => sub {
	local $ENV{GENESIS_NOCOLOR};
	delete $ENV{GENESIS_NOCOLOR};
	my @links;
	my $result = process_markdown_block('Text ~~struck~~ more', width => 40, links => \@links);
	like $result, qr/struck/, 'strikethrough text content present';
	like $result, qr/\e\[9m/, 'ANSI strikethrough sequence injected';
};

subtest 'process_markdown_block - link extraction appends to links array' => sub {
	my @links;
	my $result = process_markdown_block('See [Genesis](https://github.com/genesis-community/genesis) for details', width => 60, links => \@links);
	ok scalar(@links) == 1, 'one link extracted';
	like $links[0][0], qr/Genesis/, 'link text captured';
	like $links[0][1], qr/https:\/\/github\.com/, 'link URL captured';
};

subtest 'process_markdown_block - link-only block returns empty string' => sub {
	my @links;
	# A footnote reference line (link definition) should return ''
	my $result = process_markdown_block("[1]: https://example.com\n", width => 40, links => [['text','[1]']]);
	is $result, '', 'link-only block returns empty string';
};

# ---------------------------------------------------------------------------
# render_markdown
# ---------------------------------------------------------------------------
subtest 'render_markdown - basic paragraph rendered' => sub {
	my $result = render_markdown('Hello world.');
	like $result, qr/Hello world/, 'paragraph text present in output';
};

subtest 'render_markdown - CRLF normalized to LF' => sub {
	my $result = render_markdown("line one\r\nline two");
	unlike $result, qr/\r/, 'no carriage returns in output';
	like $result, qr/line one/, 'first line present';
};

subtest 'render_markdown - multiple blocks separated by blank lines' => sub {
	my $result = render_markdown("First block.\n\nSecond block.");
	like $result, qr/First block/, 'first block present';
	like $result, qr/Second block/, 'second block present';
};

subtest 'render_markdown - header rendered in output' => sub {
	my $result = render_markdown("# My Header\n\nSome text.");
	my $plain = decolorize($result);
	like $plain, qr/My Header/, 'H1 header text present';
	like $plain, qr/Some text/, 'paragraph text present';
};

subtest 'render_markdown - links section appended when links found' => sub {
	my $result = render_markdown('See [Example](https://example.com) here.', width => 80);
	like $result, qr/Links/, 'Links section header appended';
	like $result, qr/https:\/\/example\.com/, 'link URL in links section';
};

subtest 'render_markdown - no links section without links' => sub {
	my $result = render_markdown('Plain text with no links.');
	unlike $result, qr/Links/, 'no Links section when no links';
};

subtest 'render_markdown - code block preserved across double-newline split' => sub {
	my $md = "Text before.\n\n```\nsome code\nmore code\n```\n\nText after.";
	my $result = render_markdown($md, width => 80);
	like decolorize($result), qr/some code/, 'code block content preserved';
	like $result, qr/Text after/, 'text after code block present';
};

subtest 'render_markdown - list items rendered' => sub {
	my $md = "- alpha\n- beta\n- gamma";
	my $result = render_markdown($md, width => 40);
	my $plain = decolorize($result);
	like $plain, qr/alpha/, 'first list item in output';
	like $plain, qr/beta/, 'second list item in output';
};

subtest 'render_markdown - table rendered with borders' => sub {
	my $md = "| Name | Val |\n|------|-----|\n| foo  | 1   |";
	my $result = render_markdown($md, width => 40);
	my $plain = decolorize($result);
	like $plain, qr/Name/, 'table header in output';
	like $plain, qr/foo/, 'table data in output';
};

subtest 'render_markdown - blockquote rendered with indent' => sub {
	my $md = "> This is a blockquote.";
	my $result = render_markdown($md, width => 40);
	like $result, qr/This is a blockquote/, 'blockquote content present';
	# Should be indented
	like $result, qr/^ {2}/, 'blockquote is indented';
};

done_testing;

# vim: ts=4 sw=4 sts=4 noet fdm=marker foldlevel=1 nu
