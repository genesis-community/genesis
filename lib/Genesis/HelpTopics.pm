package Genesis::HelpTopics;
use strict;
use warnings;

use Genesis qw/info output error bail debug trace/;
use Genesis::Term qw/render_markdown terminal_width wrap/;
use File::Find;
use File::Spec;
use File::Basename;

use base 'Exporter';
our @EXPORT = qw/
	list_help_topics
	show_help_topic
	is_help_topic
	get_topic_content
/;

# Base path for help topics
sub help_topics_path {
	my $base = $ENV{GENESIS_LIB} || File::Spec->catdir(dirname($INC{'Genesis.pm'}));
	return File::Spec->catdir($base, 'Genesis', 'Help', 'Topics');
}

# List all available help topics
sub list_help_topics {
	my $topics_dir = help_topics_path();
	
	unless (-d $topics_dir) {
		error "Help topics directory not found at $topics_dir";
		return;
	}
	
	my @topics;
	opendir(my $dh, $topics_dir) or bail "Cannot open help topics directory: $!";
	
	while (my $entry = readdir($dh)) {
		next if $entry =~ /^\./;  # Skip hidden files
		next unless -d File::Spec->catdir($topics_dir, $entry);
		
		# Parse topic directory name
		my ($order, $name) = $entry =~ /^(\d+)-(.+)$/ ? ($1, $2) : (999, $entry);
		
		# Read topic metadata from index.md
		my $index_file = File::Spec->catfile($topics_dir, $entry, 'index.md');
		my $title = $name;
		my $description = '';
		
		if (-f $index_file) {
			if (open my $fh, '<', $index_file) {
				my $first_line = 1;
				while (my $line = <$fh>) {
					if ($first_line && $line =~ /^#\s+(.+)/) {
						$title = $1;
						$first_line = 0;
					} elsif ($line =~ /\S/ && $line !~ /^#/) {
						$description = $line;
						chomp $description;
						last;
					}
				}
				close $fh;
			}
		}
		
		push @topics, {
			dir => $entry,
			name => $name,
			title => $title,
			description => $description,
			order => $order
		};
	}
	closedir($dh);
	
	# Sort by order number
	@topics = sort { $a->{order} <=> $b->{order} } @topics;
	
	# Display topics list
	my $width = terminal_width();
	
	output "#G{Genesis Help Topics}\n";
	output "=" x $width . "\n\n";
	
	for my $topic (@topics) {
		my $header = sprintf("#C{%-20s} #G{%s}", $topic->{name}, $topic->{title});
		output wrap($header, $width, '', 22) . "\n";
		
		if ($topic->{description}) {
			output wrap($topic->{description}, $width, ' ' x 22, 22) . "\n";
		}
		output "\n";
	}
	
	output wrap(
		"Use '#C{genesis help <topic>}' to view a topic, or '#C{genesis help <topic>/<subtopic>}' " .
		"for a specific subtopic.",
		$width
	) . "\n";
}

# Check if a given string is a help topic
sub is_help_topic {
	my ($topic) = @_;
	
	# Special case for 'topics' command
	return 0 if $topic eq 'topics';
	
	# Check if it's a command first
	return 0 if defined($Genesis::Commands::GENESIS_COMMANDS{$topic});
	
	# Check if topic directory exists
	my $topics_dir = help_topics_path();
	return 0 unless -d $topics_dir;
	
	# Handle topic/subtopic format
	my ($main_topic, $subtopic) = split('/', $topic, 2);
	
	# Find matching topic directory
	my $dh;
	unless (opendir($dh, $topics_dir)) {
		debug "Cannot open help topics directory: $!";
		return 0;
	}
	
	my $found = 0;
	while (my $entry = readdir($dh)) {
		next if $entry =~ /^\./;
		next unless -d File::Spec->catdir($topics_dir, $entry);
		
		my ($order, $name) = $entry =~ /^(\d+)-(.+)$/ ? ($1, $2) : (999, $entry);
		if ($name eq $main_topic) {
			# If no subtopic, topic exists
			unless (defined $subtopic) {
				$found = 1;
				last;
			}
			
			# Check if subtopic file exists
			my $subtopic_file = File::Spec->catfile($topics_dir, $entry, "$subtopic.md");
			if (-f $subtopic_file) {
				$found = 1;
				last;
			}
		}
	}
	closedir($dh);
	
	return $found;
}

# Get the content of a help topic
sub get_topic_content {
	my ($topic) = @_;
	
	my $topics_dir = help_topics_path();
	my ($main_topic, $subtopic) = split('/', $topic, 2);
	
	# Find the topic directory
	my $topic_dir;
	opendir(my $dh, $topics_dir) or bail "Cannot open help topics directory: $!";
	while (my $entry = readdir($dh)) {
		next if $entry =~ /^\./;
		next unless -d File::Spec->catdir($topics_dir, $entry);
		
		my ($order, $name) = $entry =~ /^(\d+)-(.+)$/ ? ($1, $2) : (999, $entry);
		if ($name eq $main_topic) {
			$topic_dir = File::Spec->catdir($topics_dir, $entry);
			last;
		}
	}
	closedir($dh);
	
	unless ($topic_dir) {
		error "Help topic '#C{$main_topic}' not found";
		return undef;
	}
	
	# Determine which file to read
	my $file = $subtopic 
		? File::Spec->catfile($topic_dir, "$subtopic.md")
		: File::Spec->catfile($topic_dir, "index.md");
	
	unless (-f $file) {
		if ($subtopic) {
			error "Subtopic '#C{$subtopic}' not found in topic '#C{$main_topic}'";
		} else {
			error "Index file not found for topic '#C{$main_topic}'";
		}
		return undef;
	}
	
	# Read the file
	open my $fh, '<', $file or bail "Cannot read help file: $!";
	my $content = do { local $/; <$fh> };
	close $fh;
	
	return $content;
}

# Show a help topic
sub show_help_topic {
	my ($topic) = @_;
	
	my $content = get_topic_content($topic);
	return unless defined $content;
	
	# Add navigation breadcrumb
	my ($main_topic, $subtopic) = split('/', $topic, 2);
	my $breadcrumb = $subtopic 
		? "#K{Help} > #K{$main_topic} > #K{$subtopic}"
		: "#K{Help} > #K{$main_topic}";
	
	output "$breadcrumb\n";
	output "#K{" . ("─" x terminal_width()) . "}\n\n";
	
	# Render the markdown content
	output render_markdown($content);
	
	# Add footer navigation
	output "\n#K{" . ("─" x terminal_width()) . "}\n";
	if ($subtopic) {
		output "See also: #C{genesis help $main_topic} (topic index)\n";
	}
	output "For all topics: #C{genesis help topics}\n";
}

1;

=head1 NAME

Genesis::HelpTopics - Help topic system for Genesis

=head1 DESCRIPTION

This module provides the help topic system for Genesis, allowing users to
browse comprehensive documentation organized by topic.

=head1 FUNCTIONS

=head2 list_help_topics()

Lists all available help topics with their descriptions.

=head2 show_help_topic($topic)

Displays the content of a specific help topic. Topics can be specified as
"topic" for the index or "topic/subtopic" for specific pages.

=head2 is_help_topic($topic)

Returns true if the given string corresponds to a valid help topic.

=head2 get_topic_content($topic)

Returns the raw content of a help topic file, or undef if not found.

=cut