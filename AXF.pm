use DAL;
use XML::LibXML;
use XML::LibXSLT;
use XML::Simple;
use Apache::AXF::Auth;
use CGI ':standard';
use strict;

package Apache::AXF;
our $VERSION = '0.7';

use Apache::Constants qw(:http);
use CGI::Cookie;
use Apache::File;
use Session;

our ($common_base, $db, $docroot, $location, $script_base, $session);

sub handler {
	my $r = shift;

	$db = new DAL;
	$docroot = $r->document_root;
	my $uri = $r->uri;
	debug(1, "URI: $uri");
	$location = $r->location;
	debug(1, "Location: $location");
	$common_base = "/.common";
	if (-d "$docroot$common_base$location"){
		$common_base .= $location;
	}
	debug(1, "Common Base: $common_base");

	my $path = $uri;
	$path =~ s/^$location\/?//;

	my @path = split /\//, $path;
	my @remainder = ();
	my $script;
	$script_base = '';
	while (@path && (! $script_base)) {
		$script = $db->script("$location/" . join('/', @path));
		unless ($script_base = $script->path){
			unshift @remainder, pop @path;
		}
	}
	unless  ($script_base){
debug(1, 'In');
		$script = $db->script($location);
debug(1, 'Out');
		unless ($script_base = $script->path){
			debug(2, 'Script is not registered.');
			return HTTP_NOT_FOUND;
		}
	}
	debug(1, "Script Base: $script_base");

	#unless ($script->anon_ok){
		################
		# Authenticate #
		################
		#my $auth = Apache::AXF::Auth::authenticate($r->headers_in->{'Cookie'});
		#debug(2, "Login: $auth");

		#if (ref($auth)){
			#############
			# Authorize #
			#############
		#	unless (Apache::AXF::Auth::authorize($auth)){
		#		$r->headers_out->{'Location'} = '/login';
		#		return HTTP_MOVED_TEMPORARILY;
		#	}
		#}
		#else {
			#########################
			# Authentication Failed #
			#########################
		#	$r->headers_out->{'Location'} = '/login';
		#	return HTTP_MOVED_TEMPORARILY;
		#}
	#}
	
	my $file;
	debug(2, "Remainder: " . join('/', @remainder));
	if (-d "$docroot$script_base/" . join('/', @remainder)){
		if ($uri =~ /\/$/){
			$file = 'index.cgi';
		}
		else {
			$r->headers_out->{'Location'} = "$uri/";
			return HTTP_MOVED_TEMPORARILY;
		}
	}
	else {
		$file = pop @remainder;
	}
	if (@remainder){
		$script_base .= '/' . join('/', @remainder);
	}
	unless (-d "$docroot$script_base"){
		debug(2, 'Registered path for script does not exist.');
		return HTTP_NOT_FOUND;
	}
	debug(1, "Script Base: $script_base");
	debug(1, "File: $file");

#	my @potent = $r->GetLocationEnv->{'potent'};
	my @potent = ('.cgi', '.pl');

	if (grep ($file =~ /$_$/, @potent)){
		debug(1, "case 0: $file");
		$session = get_session($r);
		return cgi($r, $file);
	}
	else {
		if ($file eq 'common.xsl'){
			$file = "$common_base/$file";
			debug(1, "case 1: $file");
		}
		elsif($file eq 'wrapper.xsl') {
			$session = get_session($r);
			$file = $session->{wrapper} || 'index.cgi';
			$file = "$script_base/$file";
			debug(1, "case 2: $file");
		}
		else {
			$file = "$script_base/$file";
			debug(1, "case 3: $file");
		}
		$r->headers_out->{'Location'} = $file;
		return HTTP_MOVED_TEMPORARILY;
	}
}

sub cgi {
	my ($r, $file) = @_;
	my ($doc, $path, $q, $row, $sql);

	###########################
	# Don't cache the results #
	###########################
	$r->no_cache(1);

	#####################
	# Read query string #
	#####################
	$q = new CGI;

	#################################
	# Place query string in session #
	#################################
	delete $session->{request};
	$session->{request} = $q->Vars;

	##########################################
	# Place Customer and Language in session #
	##########################################
	$session->{proxy} ||= $ENV{REMOTE_USER};
	$session->{customer} = $ENV{REMOTE_USER};
	unless ($session->{lang}){
		unless ($session->{lang} = $q->param('lang')) {
			my ($browser_langs, @browser_langs, $lang, @msg_langs);
			$browser_langs = $r->headers_in->{'ACCEPT_LANGUAGE'};
			$browser_langs =~ s/ //g;
			@browser_langs = split /,/, $browser_langs;
			@msg_langs = $db->message->all_langs;
			foreach $lang (@browser_langs){
				if (($session->{lang}) = grep($lang =~ /^$_/, @msg_langs)){
					last;
				}
			}
			$session->{lang} ||= 'en';
		}
	}
	$session->write;

	###############################
	# Execute the common index.pl #
	###############################
	my $common_data = '';
	my $realfile = "$docroot$common_base/index.pl";	
	if (-r $realfile){
		require $realfile;
		($common_data) = common_content($session); #Call to common_base/index.pl
		delete $INC{$realfile};
	}

	#######################
	# Execute script file #
	#######################
	$realfile = "$docroot$script_base/$file";	
	unless (-r $realfile){
		debug(2, "Unable to find $realfile");
		return HTTP_NOT_FOUND;
	}
	my $script_data = '';
	require $realfile;
	($script_data, $session->{wrapper}) = content($session);
	delete $INC{$realfile};

	############################
	# Store wrapper in session #
	############################
	$session->{wrapper} ||= 'index.xsl';
	$session->write;

	###############################
	# Build complete xml response #
	###############################
	my $xml = XML::Simple::XMLout({'common' => $common_data,
		'script' => $script_data}, 'keyattr'=>[], 'rootname'=>'response', 'noattr'=>1);
					
	##########################################
	# Check to see if browser is xsl-capable #
	##########################################
	my ($agent, @certbrowsers, $certified);
	push @certbrowsers, 'Gecko';
	push @certbrowsers, 'MSIE 6';

	$certified = 0;
	$agent = $r->headers_in->{'User-Agent'};
	debug(4, "Agent: $agent");
	if (grep($agent =~ /$_/i, @certbrowsers)) {
			$certified = 1;
	}
	if ($certified){
		###########################################
		# Just send xml for client-side transform #
		###########################################
		$doc = "<?xml version=\"1.0\" encoding=\"utf-8\" ?>
<?xml-stylesheet href=\"common.xsl\" type=\"text/xsl\" ?>\n$xml";
		$r->content_type('text/xml');
		$r->send_http_header();
		unless($r->header_only){
			print $doc;
		}
	}
	else {
		###############################################
		# Do server-side transform and return results #
		###############################################
		$doc = "<?xml version=\"1.0\" encoding=\"utf-8\" ?>\n$xml";

		$r->content_type('text/html');
		$r->send_http_header();
		unless($r->header_only){
			print transform($doc, $session->{wrapper});
		}
	}
	return HTTP_OK;
}

sub get_xsl {
	debug(4, "Common XSL: $docroot$common_base/common.xsl");
        open (XSL, "$docroot$common_base/common.xsl");
	local $/;
	my $xsl = <XSL>;
        close (XSL);
	debug(4, "Common XSL:\n\t$xsl");
        return $xsl;
}


sub transform {
        my ($xml, $wrapper) = @_;
	my $xsl = get_xsl();

	#############################################################
	# Transform must be run from script's path to find includes #
	#############################################################
	chdir("$docroot$script_base");

	############################################
	# Setup Input Callback Subroutines for XML #
	############################################
	my $wrapper_match = sub {
		my $uri = shift;
		if (($uri eq 'wrapper.xsl') || ($uri =~ /^$common_base/)){
			return 1;
		}
		else {
			return 0;
		}
	};

	my $wrapper_open = sub {
		my $uri = shift;
		my ($wrap);

		if ($uri =~ /^$common_base/){
			$wrap = new Apache::File($docroot . $uri);
			debug(4, "Transform Open: $uri -> $docroot$uri");
		}
		if ($uri eq 'wrapper.xsl'){
			$wrap = new Apache::File($wrapper);
			debug(4, "Transform Open: $uri -> $wrapper");
		}

		return $wrap;
	};

	my $wrapper_read = sub {
		my $handler = shift;
		my $length = shift;
		my $buffer;
		read($handler, $buffer, $length);
		return $buffer;
	};

	my $wrapper_close = sub {
		my $wrap = shift;
		$wrap->close;
	};

        my ($parser, $source, $xslt, $style_doc, $stylesheet, $results);

	##################################
	# Perform XML and XSL processing #
	##################################
        $parser = XML::LibXML->new();
	$parser->callbacks($wrapper_match, $wrapper_open, $wrapper_read, $wrapper_close);
        $xslt = XML::LibXSLT->new();
        $source = $parser->parse_string($xml);
        $style_doc = $parser->parse_string($xsl);
        $stylesheet = $xslt->parse_stylesheet($style_doc);
        $results = $stylesheet->transform($source);
        return $stylesheet->output_string($results);
}

sub get_session {
	my ($r) = @_;
	my ($cookie, %cookies, $session);

	%cookies = parse CGI::Cookie($r->headers_in->{'Cookie'});
	if ($cookie = $cookies{'sid'}){
		my $sid = $cookie->value;
		$session = Session->read($sid);
		debug(3, "Session (Read from cookie): " . $session->id);
	}
	else {
		$session = new Session;
		debug(4, "Cookies: " . %cookies);
		debug(3, "Session (New): " . $session->id);

		#########################
		# Write cookie with sid #
		#########################
		$cookie = CGI::Cookie->new(
			-name => 'sid',
			-value => $session->id,
			-path => $location,
			-secure => 0
		);
		$r->headers_out->{'Set-Cookie'} = $cookie;
		#$r->headers_out->{'Set-Cookie'} = "sid=" . $session->id . "; path=$location";
	}


	return $session;
}

sub debug {
	my ($lvl, $msg) = @_;
	my $debug = 4;

	if ($lvl <= $debug){
		print STDERR "$msg\n";
	}
}

1;
