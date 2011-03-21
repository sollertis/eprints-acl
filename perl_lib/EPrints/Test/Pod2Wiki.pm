package EPrints::Test::Pod2Wiki;

=for Pod2Wiki

=head1 NAME

EPrints::Test::Pod2Wiki - convert EPrints pod to MediaWiki

=head1 Editing Pod2Wiki Pages

Pages generated by this module have Pod2Wiki markers inserted. These markers are HTML comments that start and end every L<Plain Old Documentation|perlpod> (POD) section. For example a POD synopsis section will look like this:

  <!-- Pod2Wiki=head_synopsis -->
  ==SYNOPSIS==
  use EPrints::Test::Pod2Wiki;
  my $p = EPrints::Test::Pod2Wiki-&gt;new(
    wiki_index =&gt; "http://wiki.foo.org/index.php",
    username =&gt; "johnd",
    password =&gt; "xiPi00",
  );
  $p-&gt;update_page( "EPrints::Utils" );
  <!-- Edit below this comment -->
  <!-- Pod2Wiki= -->

When the Wiki page is updated each Pod2Wiki section is replaced with the equivalent section content from the POD.

Comments can be made by adding them to the comment sections:

  ...
  <!-- Pod2Wiki=head_methods -->
  ==METHODS==
  Any changes here will be lost
  <!-- Edit below this comment -->
  This Wiki comment will be kept.
  <!-- Pod2Wiki= -->
  ...

Note: if a POD section is removed any Wiki content associated with that section will also be removed.

The rest of this page concerns the I<EPrints::Test::Pod2Wiki> module.

=head1 SYNOPSIS

	use EPrints::Test::Pod2Wiki;

	my $p = EPrints::Test::Pod2Wiki->new(
		wiki_index => "http://wiki.foo.org/index.php",
		username => "johnd",
		password => "xiPi00",
		);

	$p->update_page( "EPrints::Utils" );

=head1 DESCRIPTION

This module enables the integration of EPrints POD (documentation) and MediaWiki pages.

=head1 METHODS

=over 4

=cut

use Pod::Parser;
@ISA = qw( Pod::Parser );

use EPrints;
use LWP::UserAgent;
use Pod::Html;
use HTML::Entities;
use HTTP::Cookies;
use Pod::Coverage;

use strict;

my $PREFIX = "Pod2Wiki=";
my $END_PREFIX = "Edit below this comment";
my $STYLE = "background-color: #e8e8f; margin: 0.5em 0em 1em 0em; border: solid 1px #cce;  padding: 0em 1em 0em 1em; font-size: 80%; ";

=item EPrints::Test::Pod2Wiki->new( ... )

Create a new Pod2Wiki parser. Required options:

  wiki_index - URL of the MediaWiki "index.php" page
  username - MediaWiki username
  password - MediaWiki password

=cut

sub new
{
	my( $class, %opts ) = @_;

	my $self = $class->SUPER::new( %opts );

	my $ua = LWP::UserAgent->new;

	$self->{_ua} = $ua;

	my $u = URI->new( $self->{wiki_index} );
	$u->query_form(
		title => "Special:Userlogin",
		action => "submitlogin",
		type => "login"
	);

	my $cookie_jar = HTTP::Cookies->new;
	$ua->cookie_jar( $cookie_jar );

	# log into the Wiki
	my $r = $ua->post( $u, [
		wpName => $opts{username},
		wpPassword => $opts{password},
		wpDomain => "eprints",
		wpLoginattempt => "Log in",
	]);

#print STDERR "$u\n", $r->headers->as_string, $r->content;

	return $self;
}

=item $ok = $pod->update_page( $package_name )

Update the MediaWiki page for $package_name.

=cut

sub update_page
{
	my( $self, $package_name ) = @_;

	_flush_seen(); # see method
	local $self->{_out} = [];
	local $self->{_is_api} = 0;
	local $self->{_p2w_pod_section};
	local $self->{_p2w_format} = "";
	local $self->{_p2w_head_depth} = 0;
	local $self->{_p2w_methods} = 0;
	local $self->{_wiki} = {};

	# locate the source file
	my $file = $self->_p2w_locate_package( $package_name );
	if( !-f $file )
	{
		print STDERR "Warning! Source file not found for $package_name: $file\n";
		return 0;
	}
	my $title = $self->_p2w_wiki_title( $package_name );

	# add the preamble
	push @{$self->{_out}}, $self->_p2w_preamble( $package_name, $title );

	# retrieve the current wiki page
	my $wiki_page = $self->_p2w_wiki_source( $title );

	# populate _wiki with any wiki content
	$self->_p2w_parse_wiki( $wiki_page );

	push @{$self->{_out}}, delete($self->{_wiki}->{"_preamble_"})
		if defined $self->{_wiki}->{"_preamble_"};

	# parse the file for POD statements
	$self->parse_from_file( $file );

	# locate unpodded-methods and add them to the wiki page
	# $self->_p2w_add_uncovered( $package_name, $file );

	# make sure that there was a $END_PREFIX
	$self->command( "pod" );

	push @{$self->{_out}},
		"<!-- ${PREFIX}_postamble_ -->",
		"<!-- $END_PREFIX -->";

	push @{$self->{_out}}, delete($self->{_wiki}->{"_postamble_"})
		if defined $self->{_wiki}->{"_postamble_"};

	if( !$self->{_is_api} )
	{
		print STDERR "Failed: Page isn't API, missing =for Pod2Wiki\n";
		return;
	}

	my $new_wiki_page = join "", @{$self->{_out}};
	if( $new_wiki_page ne $wiki_page )
	{
		if( $self->_p2w_post_new_page( $title, $new_wiki_page ) )
		{
			print STDERR "Ok\n" 
		}
		else
		{
			print STDERR "Failed: error posting page\n" 
		}
	}
	else
	{
		print STDERR "Ok: Nothing changed\n";
	}
}

sub _p2w_post_new_page
{
	my( $self, $title, $content ) = @_;

	my $u = URI->new( $self->{wiki_index} );
	$u->query_form(
		title => $title,
		action => "edit"
	);
	my $r = $self->{_ua}->get( $u );
	my( $edit_time ) = $r->content =~ /<input (.*?wpStarttime.*?)\/>/;
	if( !$edit_time )
	{
		print STDERR "Error following edit link for page\n";
		return;
	}
	$edit_time = $edit_time =~ /value=["']([^"']+)/;
	my( $edit_token ) = $r->content =~ /<input (.*?wpEditToken.*?)\/>/;
	($edit_token) = $edit_token =~ /value=["']([^"']+)/;
	my( $auto_summary ) = $r->content =~ /<input (.*?wpAutoSummary.*?)\/>/;
	($auto_summary) = $auto_summary =~ /value=["']([^"']+)/;
	$u->query_form(
		title => $title,
		action => "submit"
	);
	$r = $self->{_ua}->post( $u, [
		wpStarttime => $edit_time,
		wpEdittime => $edit_time,
		wpSection => "",
		wpTextbox1 => $content,
		wpSave => "Save page",
		wpEditToken => $edit_token,
		wpAutoSummary => $auto_summary,
		wpScrolltop => 0,
		wpSummary => "",
		wpRecreate => 1, # MediaWiki throws a fit on previously deleted pages
	]);
	if( $r->code ne "302" )
	{
		print STDERR "Error posting update to: $u: ".$r->message."\n";
	}
	return $r->code eq "302";
}

# preamble blurb for the Wiki output (placed in a comment)
sub _p2w_preamble
{
	my( $self, $package_name, $title ) = @_;

	my $blurb = <<EOC;
This page has been automatically generated from the EPrints 3.2 source. Any wiki changes made between the '$PREFIX*' and '$END_PREFIX' comments will be lost.
EOC

	my $sort_key = uc($package_name);
	$sort_key =~ s/^.*:://;

	my $file = $package_name;
	$file =~ s/::/\//g;
	$file = "$file.pm";

	my $parent = $package_name;
	$parent =~ s/::[^:]+$//;
	$parent =~ s#::#/#g;
	undef $parent if $parent !~ m#/#;

	my $selfcat = $package_name;
	$selfcat =~ s#::#/#g;
	undef $selfcat if $selfcat !~ m#/#;

	return (
		"<!-- ${PREFIX}_preamble_ \n$blurb -->",
#		"\n__NOTOC__\n",
		"{{API}}",
		"{{Pod2Wiki}}",
		"{{API:Source|file=$file|package_name=$package_name}}",
		"[[Category:API|$sort_key]]",
		($parent ? "[[Category:API:$parent|$sort_key]]" : ()),
		($selfcat ? "[[Category:API:$selfcat|$sort_key]]" : ()),
		"<div>",
		"<!-- $END_PREFIX -->\n\n\n",
	);
}

# returns the filename that package will use
sub _p2w_locate_package
{
	my( $self, $package_name ) = @_;

	my $base_path = $EPrints::SystemSettings::conf->{base_path};

	if( $package_name =~ m#/# )
	{
		return "$base_path/$package_name";
	}

	my $perl_lib = "$base_path/perl_lib";
	my $file = $package_name;
	$file =~ s/::/\//g;
	$file = "$perl_lib/$file.pm";

	return $file;
}

# what title we should use based on the perl package name
sub _p2w_wiki_title
{
	my( $self, $package_name ) = @_;

	$package_name =~ s/::/\//g;

	return "API:$package_name";
}

# retrieve the Wiki source page
sub _p2w_wiki_source
{
	my( $self, $title ) = @_;

	my $u = URI->new( $self->{wiki_index} );
	$u->query_form(
		title => $title,
		action => "raw",
	);

	my $r = $self->{_ua}->get( $u );

	return $r->is_success ? $r->content : "";
}

# parse the Wiki source and record any Wiki that may have been added to the
# basic POD translation
sub _p2w_parse_wiki
{
	my( $self, $content ) = @_;

	my %wiki;
	my $pod_section = "_preamble_";
	my $in_pod = 0;

	for($content) {
		pos($_) = 0;
		while(pos($_) < length($_))
		{
# start of a POD section
			if( /\G<!-- $PREFIX([^\s]*) .*?-->/sgoc )
			{
				$pod_section = $1;
				$in_pod = 1;
				next;
			}
# end of previous POD section
			if( $in_pod && m/\G<!-- $END_PREFIX -->/sgoc )
			{
				$in_pod = 0;
				next;
			}
# ignore POD
			$in_pod && /\G.+?<!--/sgc && (pos($_)-=4, next);
# capture Wiki content
			/\G(.+?)<!--/sgc && (pos($_)-=4, $wiki{$pod_section} .= $1, next);
# trailing stuff
			$in_pod && /\G.+/sgc && (next);
			/\G.+/sgc && ($wiki{$pod_section} .= $1, next);
			Carp::confess "Oops: got to end of parse loop and didn't match: '".substr($_,pos($_),40) . " ...'";
		}
	}

	foreach my $key (keys %wiki)
	{
		$wiki{$key} =~ s/^\n\n+/\n/;
		delete $wiki{$key} unless $wiki{$key} =~ /\S/;
	}

	$self->{_wiki} = \%wiki;
}

sub _p2w_add_uncovered
{
	my( $self, $package_name, $file ) = @_;

	my $parser = Pod::Coverage->new(
		package => $package_name,
		pod_from => $file,
	);

	my @methods = sort $parser->uncovered();

	return unless scalar @methods > 0;

	$self->command( "head1", "UNDOCUMENTED METHODS", 0, Pod::Paragraph->new(
		-text => "UNDOCUMENTED METHODS",
		-name => "head1" ) );
	push @{$self->{_out}},
		"{{API:Undocumented Methods}}";
	$self->command( "over", "", 0, Pod::Paragraph->new(
		-text => "",
		-name => "over" ) );

	foreach my $ref (@methods)
	{
		$self->command( "item", $ref, 0, Pod::Paragraph->new(
			-text => $ref,
			-name => "item" ) );
	}

	$self->command( "back", "", 0, Pod::Paragraph->new(
		-text => "",
		-name => "back" ) );
}

=item $parser->command( ... )

L<Pod::Parser> callback.

=cut

sub command
{
	my( $self, $cmd, $text, $line_num, $pod_para ) = @_;

	if( $self->{_p2w_pod_section} )
	{
		if( $self->{_p2w_pod_section} eq "begin" )
		{
			if( $cmd eq "end" )
			{
				$self->{_p2w_format} = "";
				delete $self->{_p2w_pod_section};
			}
			return;
		}
		my $key = delete $self->{_p2w_pod_section};
		push @{$self->{_out}}, "<div style='$STYLE'>\n<span style='display:none'>User Comments</span>\n<!-- $END_PREFIX -->\n\n";
		if( $self->{_wiki}->{$key} )
		{
			push @{$self->{_out}},
				delete $self->{_wiki}->{$key};
		}
		push @{$self->{_out}}, "\n<!-- ${PREFIX} -->\n</div>\n";
	}
	return if $cmd eq "pod";

	$text =~ s/\n+//g;
	my $key = EPrints::Utils::escape_filename( $text );
	my $ref = lc( _p2w_fragment_id( $text ) );
	$text = $self->interpolate( $text, $line_num );

	if( $cmd =~ /^head(\d+)/ )
	{
		$self->{_p2w_head_depth} = $1;
		my $eqs = "=" x $1;
		$eqs .= "="; # start at == not =
		push @{$self->{_out}}, 
			"<!-- ${PREFIX}head_$ref -->\n",
			"$eqs$text$eqs\n";
		$self->{_p2w_pod_section} = "head_$ref";
		if( $ref eq "methods" )
		{
			$self->{_p2w_methods} = $self->{_p2w_head_depth};
		}
		elsif( $self->{_p2w_methods} == $self->{_p2w_head_depth} )
		{
			$self->{_p2w_methods} = 0;
		}
	}
	elsif( $cmd eq "over" or $cmd eq "back" )
	{
	}
	elsif( $cmd eq "item" )
	{
		my $depth = $self->{_p2w_head_depth} || 0;
		++$depth;
		my $eqs = "=" x $depth;
		$eqs .= "="; # start at == not =
		push @{$self->{_out}}, "<!-- ${PREFIX}item_$ref -->\n";
		if( $self->{_p2w_methods} )
		{
			$ref = $text if !$ref;
			push @{$self->{_out}}, 
				"$eqs$ref$eqs\n\n",
				" $text\n";
		}
		else
		{
			push @{$self->{_out}}, "$eqs$text$eqs\n\n";
		}
#		if( $ref ne $text )
#		{
#			push @{$self->{_out}}, "  $text\n\n";
#		}
		$self->{_p2w_pod_section} = "item_$ref";
	}
	elsif( $cmd eq "for" )
	{
		my( $type, $value ) = split /\s+/, $text, 2;
		if( $type eq "Pod2Wiki" )
		{
			push @{$self->{_out}}, "<!-- ${PREFIX}_private_ -->";
			$self->{_is_api} = 1;
			push @{$self->{_out}}, $value if $value;
		}
	}
	elsif( $cmd eq "begin" )
	{
		$self->{_p2w_pod_section} = $cmd;
		if( $text eq "Pod2Wiki" )
		{
			$self->{_p2w_format} = $text;
			push @{$self->{_out}}, "<!-- ${PREFIX}_private_ -->";
		}
	}
	else
	{
		$text =~ s/[\r\n]+$//s;
		push @{$self->{_out}},
			"<!-- ${PREFIX}$cmd -->\n",
			$text;
		$self->{_p2w_pod_section} = $cmd;
	}
}

=item $parser->verbatim( ... )

L<Pod::Parser> callback.

=cut

sub verbatim
{
	my( $self, $text, $line_num, $pod_para ) = @_;

	return unless $self->{_p2w_pod_section};
	return if $self->{_p2w_pod_section} eq "begin" && $self->{_p2w_format} ne "Pod2Wiki";
	$text = $self->interpolate( $text, $line_num );
	# tabs = indented
	$text =~ s/\t/  /g;
	$text =~ s/\n\n/\n  \n/g;
	push @{$self->{_out}}, $text;
}

=item $parser->textblock( ... )

L<Pod::Parser> callback.

=cut

sub textblock
{
	my( $self, $text, $line_num, $pod_para ) = @_;

	return unless $self->{_p2w_pod_section};
	if( $self->{_p2w_pod_section} eq "begin" )
	{
		if( $self->{_p2w_format} eq "Pod2Wiki" )
		{
			push @{$self->{_out}}, $text;
		}
		return;
	}
	$text = $self->interpolate( $text, $line_num );
	push @{$self->{_out}}, $text;
}

=item $parser->interpolate( ... )

L<Pod::Parser> callback. Overloaded to also escape HTML entities.

=cut

sub interpolate
{
	my( $self, $text, $line_num ) = @_;

	$text = $self->SUPER::interpolate( $text, $line_num );
	# join wrapped lines together
	$text =~ s/([^\n])\n([^\s])/$1 $2/g;
	$text = HTML::Entities::encode_entities( $text, "<>&" );
	$text =~ s/\x00([a-z0-9]+)\x00([^\x00]+)\x00/<$1>$2<\/$1>/g;

	return $text;
}

=item $parser->interior_sequence( ... )

L<Pod::Parser> callback.

=cut

sub interior_sequence
{
	my( $self, $seq_cmd, $seq_arg, $pod_seq ) = @_;

	# shouldn't happen (and breaks =item text)
#	return unless $self->{_p2w_pod_section};

	return "'''$seq_arg'''" if $seq_cmd eq 'B';
	return "\x{00}tt\x00$seq_arg\x00" if $seq_cmd eq 'C';
	return "\x{00}em\x00$seq_arg\x00" if $seq_cmd eq 'I';
	return "\x{00}u\x00$seq_arg\x00" if $seq_cmd eq 'U';
	if( $seq_cmd eq "E" )
	{
		return {
			'lt' => "<",
			'gt' => ">",
			'verbar' => "|",
			'sol' => "/",
		}->{$seq_arg} || "$seq_cmd!$seq_arg!";
	}
	if( $seq_cmd eq "L" )
	{
		# mediawiki should take care of URL highlighting for us
		if( $seq_arg =~ /^(?:(?:https?)|(?:ftp)|(?:mailto)):/ )
		{
			return $seq_arg;
		}
		# link to the API wiki page
		elsif( $seq_arg =~ /^EPrints\b/ )
		{
			my( $text, $module, $sec ) = $self->_p2w_split_pod_link( $seq_arg );
			if( defined $module )
			{
				my $title = $self->_p2w_wiki_title( $module );
				if( defined $sec )
				{
					$sec =~ s/ /_/g;
					return "[[$title#$sec|$text]]";
				}
				else
				{
					return "[[$title|$text]]";
				}
			}
			elsif( defined $sec )
			{
				return "[[#$sec|$text]]";
			}
		}
		else
		{
			my( $text, $module, $sec ) = $self->_p2w_split_pod_link( $seq_arg );
			if( defined $module )
			{
				my $file = $module;
				$file =~ s/::/\//g;
				if( defined $sec )
				{
					return "{{API:PodLink|file=$file|package_name=$module|section=$sec|text=$text}}";
				}
				else
				{
					return "{{API:PodLink|file=$file|package_name=$module|section=|text=$text}}";
				}
			}
		}
	}
	return "$seq_cmd!$seq_arg!";
}

sub _p2w_split_pod_link
{
	my( $self, $seq_arg ) = @_;

	my( $text, $name ) = split /\|/, $seq_arg;
	$name = $text if !defined $name;
	my( $module, $sec ) = split /\//, $name;
	if( $module =~ /^"(.+)"$/ )
	{
		$sec = $1;
		$module = undef;
	}
	if( defined $sec )
	{
		$sec =~ s/^"(.+)"$/$1/;
	}

	return( $text, $module, $sec );
}

# Copied from Pod::Html
# Takes a string e.g. =item text and returns a likely identifier (method name)
sub _p2w_fragment_id
{
    my $text     = shift;
    my $generate = shift;   # optional flag

    $text =~ s/\s+\Z//s;
    if( $text ){
        # a method or function?
        return $1 if $text =~ /(\w+)\s*\(/;
        return $1 if $text =~ /->\s*(\w+)\s*\(?/;

        # a variable name?
        return $1 if $text =~ /^([\$\@%*]\S+)/;

        # some pattern matching operator?
        return $1 if $text =~ m|^(\w+/).*/\w*$|;

        # fancy stuff... like "do { }"
        return $1 if $text =~ m|^(\w+)\s*{.*}$|;

        # honour the perlfunc manpage: func [PAR[,[ ]PAR]...]
        # and some funnies with ... Module ...
        return $1 if $text =~ m{^([a-z\d_]+)(\s+[A-Z,/& ][A-Z\d,/& ]*)?$};
        return $1 if $text =~ m{^([a-z\d]+)\s+Module(\s+[A-Z\d,/& ]+)?$};

        return _fragment_id_readable($text, $generate);
    } else {
        return;
    }
}

{
    my %seen;   # static fragment record hash

sub _flush_seen {
	%seen = ();
}

sub _fragment_id_readable {
    my $text     = shift;
    my $generate = shift;   # optional flag

    my $orig = $text;

    # leave the words for the fragment identifier,
    # change everything else to underbars.
    $text =~ s/[^A-Za-z0-9_]+/_/g; # do not use \W to avoid locale dependency.
    $text =~ s/_{2,}/_/g;
    $text =~ s/\A_//;
    $text =~ s/_\Z//;

    unless ($text)
    {
        # Nothing left after removing punctuation, so leave it as is
        # E.g. if option is named: "=item -#"

        $text = $orig;
    }

    if ($generate) {
        if ( exists $seen{$text} ) {
            # This already exists, make it unique
            $seen{$text}++;
            $text = $text . $seen{$text};
        } else {
            $seen{$text} = 1;  # first time seen this fragment
        }
    }

    $text;
}}

1;

=head1 COPYRIGHT

=for COPYRIGHT BEGIN

Copyright 2000-2011 University of Southampton.

=for COPYRIGHT END

=for LICENSE BEGIN

This file is part of EPrints L<http://www.eprints.org/>.

EPrints is free software: you can redistribute it and/or modify it
under the terms of the GNU Lesser General Public License as published
by the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

EPrints is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
License for more details.

You should have received a copy of the GNU Lesser General Public
License along with EPrints.  If not, see L<http://www.gnu.org/licenses/>.

=for LICENSE END

