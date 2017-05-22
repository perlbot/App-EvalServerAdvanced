#!/usr/bin/env perl

use lib '/eval/elib';

use strict;
use Data::Dumper;
use Scalar::Util; #Required by Data::Dumper
use File::Glob;
use POSIX;
use List::Util qw/reduce/;
use Cwd;
use FindBin;

# Modules expected by many evals, load them now to avoid typing in channel
use Encode qw/encode decode/;
use IO::String;
use File::Slurper qw/read_text/;
use EvalServer::Seccomp;
use EvalServer::Config;
use File::Temp;

# Easter eggs
do {package Tony::Robbins; sub import {die "Tony Robbins hungry: https://www.youtube.com/watch?v=GZXp7r_PP-w\n"}; $INC{"Tony/Robbins.pm"}=1};
do {
    package Zathras; 
    our $AUTOLOAD; 
    use overload '""' => sub {
        my $data = @{$_[0]{args}}? qq{$_[0]{data}(}.join(', ', map {"".$_} @{$_[0]{args}}).qq{)} : qq{$_[0]{data}};
        my $old = $_[0]{old};

        my ($pack, undef, undef, $meth) = caller(1);

        if ($pack eq 'Zathras' && $meth ne 'Zahtras::dd_freeze') {
            if (ref($old) ne 'Zathras') {
                return "Zathras->$data";
            } else {
                return "${old}->$data";
            }
        } else {
           $old = "" if (!ref($old));
           return "$old->$data"
        }
      };
    sub AUTOLOAD {$AUTOLOAD=~s/.*:://; bless {data=>$AUTOLOAD, args => \@_, old => shift}}
    sub DESTROY {}; # keep it from recursing
    sub dd_freeze {$_[0]=\($_[0]."")}
    sub can {my ($self, $meth) = @_; return sub{$self->$meth(@_)}}
    };

$|++;
#*STDOUT = $stdh;

no warnings;

# This sub is defined here so that it is defined before the 'use charnames'
# command. This causes extremely strange interactions that result in the
# deparse output being much longer than it should be.
	sub deparse_perl_code {
		my( $code ) = @_;
      my $sub;
      {
          no strict; no warnings; no charnames;
          $sub = eval "use $]; package botdeparse; sub{ $code\n }; use namespace::autoclean;";
      }

      my %methods = (map {$_ => botdeparse->can($_)} grep {botdeparse->can($_)} keys {%botdeparse::}->%*);

      if( $@ ) { print STDOUT "Error: $@"; return }

      my $dp = B::Deparse->new("-p", "-q", "-x7", "-d");
      local *B::Deparse::declare_hints = sub { '' };
      my @out;

      my $clean_out = sub {
        my $ret = shift;
        $ret =~ s/\{//;
        $ret =~ s/package (?:\w+(?:::)?)+;//;
        $ret =~ s/no warnings;//;
        $ret =~ s/\s+/ /g;
        $ret =~ s/\s*\}\s*$//;
        $ret =~ s/no feature ':all';//;
        $ret =~ s/use feature [^;]+;//;
        $ret =~ s/^\(\)//g;
        $ret =~ s/^\s+|\s+$//g;
        return $ret;
      };

      for my $sub (grep {!/^(can|DOES|isa)$/} keys %methods) {
        my $ret = $clean_out->($dp->coderef2text($methods{$sub}));

        push @out, "sub $sub {$ret} ";
      }
      
      my $ret = $dp->coderef2text($sub);
      $ret = $clean_out->($ret);
      push @out, $ret;

      my $fullout = join(' ', @out);

       use Perl::Tidy; 
       my $hide = do {package hiderr; sub print{}; bless {}}; 
       my $tidy_out="";
       eval {
         my $foo = "$fullout";
         Perl::Tidy::perltidy(source => \$foo, destination => \$tidy_out, errorfile => $hide, logfile => $hide);
       };

      $tidy_out = $fullout if ($@);

      print STDOUT $tidy_out;
	}

# Required for perl_deparse
use B::Deparse;

## Javascript Libs
#BEGIN{ eval "use JavaScript::V8; require JSON::XS; JavaScript::V8::Context->new()->eval('1')"; }
#my $JSENV_CODE = do { local $/; open my $fh, "deps/env.js"; <$fh> };
#require 'bytes_heavy.pl';

 binmode STDOUT, ":encoding(utf8)"; # Enable utf8 output.

  my ($type, $code) = @ARGV; # Take these from ARGV now

  # redirect STDIN to /dev/null, to avoid warnings in convoluted cases.
  # we have to leave this open for perl4, so only do this for other systems
  open STDIN, '<', '/dev/null' or die "Can't open /dev/null: $!";

  # This should stay in place, that way we don't let people accidentally run as root
	die "Failed to drop root: $<" if $< == 0;
	# close STDIN;

  # Setup SECCOMP for us
  my ($profile) = ($type =~ /^([a-z]+)/ig);
  $profile = "perl" if $type eq 'deparse';
  my $esc = EvalServer::Seccomp->new(profiles => ["lang_$profile"], exec_map => config->language);
  $esc->engage();
	
	# Choose which type of evaluation to perform
	# will probably be a dispatch table soon.
	if( $type eq 'perl' or $type eq 'pl' ) {
		perl_code($code);
	}
	elsif( $type eq 'deparse' ) {
		deparse_perl_code($code);
	}
  elsif ($type =~ /perl([0-9.]+)/) { # run specific perl version
    perl_version_code($1, $code);
  }
	elsif( $type eq 'javascript' ) {
		javascript_code($code);
	}
	elsif( $type eq 'ruby' ) {
		ruby_code($code);
	}
  else {
    die "Failed to find language $type";
  }

	exit;

	#-----------------------------------------------------------------------------
	# Evaluate the actual code
	#-----------------------------------------------------------------------------
	sub perl_code {
		my( $code ) = @_;

    my $outbuffer = "";
    open(my $stdh, ">", \$outbuffer);
    select($stdh);
    $|++;

		local $@;
		local @INC = map {s|/home/ryan||r} @INC;
#        local $$=24601;
        close STDIN;
        my $stdin = q{Biqsip bo'degh cha'par hu jev lev lir loghqam lotlhmoq nay' petaq qaryoq qeylis qul tuq qaq roswi' say'qu'moh tangqa' targh tiq 'ab. Chegh chevwi' tlhoy' da'vi' ghet ghuy'cha' jaghla' mevyap mu'qad ves naq pach qew qul tuq rach tagh tal tey'. Denibya' dugh ghaytanha' homwi' huchqed mara marwi' namtun qevas qay' tiqnagh lemdu' veqlargh 'em 'e'mam 'orghenya' rojmab. Baqa' chuy da'nal dilyum ghitlhwi' ghubdaq ghuy' hong boq chuydah hutvagh jorneb law' mil nadqa'ghach pujwi' qa'ri' ting toq yem yur yuvtlhe' 'e'mamnal 'iqnah qad 'orghenya' rojmab 'orghengan. Beb biqsip 'ugh denibya' ghal ghobchuq lodni'pu' ghochwi' huh jij lol nanwi' ngech pujwi' qawhaq qeng qo'qad qovpatlh ron ros say'qu'moh soq tugh tlhej tlhot verengan ha'dibah waqboch 'er'in 'irneh.
Cha'par denib qatlh denibya' ghiq jim megh'an nahjej naq nay' podmoh qanwi' qevas qin rilwi' ros sila' tey'lod tus vad vay' vem'eq yas cha'dich 'entepray' 'irnehnal 'urwi'. Baqa' be'joy' bi'res chegh chob'a' dah hos chohwi' piq pivlob qa'ri' qa'rol qewwi' qo'qad qi'tu' qu'vatlh say'qu'moh sa'hut sosbor'a' tlhach mu'mey vid'ir yas cha'dich yergho. Chegh denibya'ngan jajvam jij jim lev lo'lahbe'ghach ngun nguq pa' beb pivlob pujwi' qab qid sosbor'a' tlhepqe' tlhov va 'o'megh 'ud haqtaj. Bor cha'nas denibya' qatlh duran lung dir ghogh habli' homwi' hoq je' notqa' pegh per pitlh qarghan qawhaq qen red tey'lod valqis vid'ir wab yer yintagh 'edjen. Bi'rel tlharghduj cheb ghal lorlod ne' ngij pipyus pivlob qutluch red sila' tuqnigh.
Chob'a' choq chuq'a' dol jev jij lev marwi' mojaq ngij ngugh pujmoh puqni'be' qaywi' qirq qi'yah qum taq tey'be' tlhup valqis 'edsehcha. Chadvay' cha'par ghal je' lir lolchu' lursa' maqmigh ngun per qen qevas quv bey' soq targh tiq tlhot veqlargh wen. Baqa' chuq'a' jev juch logh lol lor mistaq nahjej nuh bey' nguq pujmoh qovpatlh ron tahqeq tuy' vithay' yo'seh yahniv yuqjijdivi' 'em 'orghenya'ngan. Beb cheb chob da'nal da'vi' ghoti' ghuy'cha' hoq loghqam ngav po ha'dibah qen qo'qad qid ril siq tuy' tlhoy' sas vinpu' wab yuqjijqa' 'em 'o'megh. Bachha' biq boqha''egh cheb dor duran lung dir ghang hos chohwi' je' luh mu'qad ves nav habli' qab qan rach siqwi' tennus tepqengwi' tuqnigh tlhoy' sas va vin yeq yuqjijdivi' 'ab 'edjen 'iqnah 'ud'a' 'urwi'.
Baqa' bi'res boq'egh da'vi' dol dor ghet ghetwi' ghogh habli' hos chohwi' nga'chuq petaq pirmus puqni' qutluch qaj qid qi'tu' qongdaqdaq siq tahqeq ti'ang toq tlhup yatqap yer 'ur. Biqsip 'ugh chang'eng choq choq hutvagh jajlo' qa' jer nanwi' nav habli' pirmus qab qa'meh vittlhegh qa'ri' sen siv vem'eq yer yo'seh yahniv yuqjijdivi' 'arlogh 'e'mamnal 'och. Chang'eng chas cha'dich choq lursa' mil natlh nay' puqni'be' qeng qid qulpa' ret sa'hut viq wen yiq yuqjijdivi' yu'egh 'edsehcha 'entepray' 'er'in 'ev 'irneh 'iw 'ip ghomey 'orwi' 'ud haqtaj 'usgheb. Chadvay' gheb lol lorbe' lursa' pivlob qep'it sen senwi' rilwi' je tajvaj wogh. Chevwi' tlhoy' huh lol lorbe' neslo' ne' pipyus qaq qi'yah tal 'ev.
Biqsip biqsip 'ugh chan ghitlh lursa' nuh bey' ngun petaq qeng soj tlhej waqboch 'ab 'entepray' 'e'mam. Bo denibya' ghetwi' ghochwi' ghuy' ghuy'cha' holqed huh jaj je' matlh pegh petaq qawhaq qa'meh qay' tagh tey' wogh yer yu'egh 'orghen 'urwi'. Boq'egh choq dav jim laq nga'chuq ngoqde' ngusdi' qan qu'vatlh sen tijwi'ghom ti'ang wogh 'orghenya'ngan. Biq cha'nas chegh chob dilyum ghetwi' juch me'nal motlh po ha'dibah puqni'lod qab qarghan qaywi' qaj rutlh say'qu'moh todsah tus yas wa'dich 'aqtu' 'edjen 'e'nal 'orwi'. Bor chob jaghla' je' jorneb mellota' meqba' nguq rachwi' ron tey' tiqnagh lemdu' vay' 'usgheb. Bis'ub cheb chob'a' dugh homwi' lotlhmoq mu'qad ves nahjej nanwi' naw' nitebha' ngoqde' ngusdi' pach pujmoh puqni'lod qan qay' rech senwi' tangqa' tepqengwi' tlhej tlhot valqis waqboch 'aqtu' 'e'mam 'iqnah 'orghen rojmab.};
        open(STDIN, "<", \$stdin);

		local $_;

        my $ret;

        my @os = qw/aix bsdos darwin dynixptx freebsd haiku linux hpux irix next openbsd dec_osf svr4 sco_sv unicos unicosmk solaris sunos MSWin32 MSWin16 MSWin63 dos os2 cygwin vos os390 os400 posix-bc riscos amigaos xenix/;

        {
#          local $^O = $os[rand()*@os];
          no strict; no warnings; package main;
#        my $oldout;
          do {
            local $/="\n";
            local $\;
            local $,;
            #$code = "use $]; use feature qw/postderef refaliasing lexical_subs postderef_qq signatures/; use experimental 'declared_refs';\n#line 1 \"(IRC)\"\n$code";
            $code = "use $]; use feature qw/postderef refaliasing lexical_subs postderef_qq signatures/;\n#line 1 \"(IRC)\"\n$code";
            $ret = eval $code;
          }
        }
        select STDOUT;

		local $Data::Dumper::Terse = 1;
		local $Data::Dumper::Quotekeys = 0;
		local $Data::Dumper::Indent = 0;
		local $Data::Dumper::Useqq = 1;
        local $Data::Dumper::Freezer = "dd_freeze";

		my $out = ref($ret) ? Dumper( $ret ) : "" . $ret;

		print $out unless $outbuffer;
    print $outbuffer;

		if( $@ ) { print "ERROR: $@" }
	}

  sub perl_version_code {
    my ($version, $code) = @_;

    my $qcode = quotemeta $code;

    my $wrapper = 'use Data::Dumper; 
    
		local $Data::Dumper::Terse = 1;
		local $Data::Dumper::Quotekeys = 0;
		local $Data::Dumper::Indent = 0;
		local $Data::Dumper::Useqq = 1;

    my $val = eval "#line 1 \"(IRC)\"\n'.$qcode.'";

    if ($@) {
      print $@;
    } else {
      $val = ref($val) ? Dumper ($val) : "".$val;
      print " ",$val;
    }
    ';

    unless ($version eq '4') {
      exec(config->language->{'perl'.$version}->bin, '-e', $wrapper) or die "Exec failed $!";
    } else {
      exec(config->language->{'perl'.$version}->bin, '-e', $code); # the code for perl4 is actually still in STDIN, if we try to -e it needs to write files
    }
  }
  
  sub ruby_code {
    my ($code) = @_;

    exec(config->language->ruby->bin, '-e', $code);
  }

  sub javascript_code {
    my ($code) = @_;

    my $ft = File::Temp->new(SUFFIX=>'.js');
    print $ft $code;
    $ft->flush();
    STDOUT->flush();
    exec(config->language->node->bin, "--v8-pool-size=1", "$ft");
  }

# 	sub javascript_code {
# 		my( $code ) = @_;
# 		local $@;
#
# 		my $js = JavaScript::V8::Context->new;
#
# 		# Set up the Environment for ENVJS
# 		$js->bind("print", sub { print @_ } );
# 		$js->bind("write", sub { print @_ } );
#
# #		for( qw/log debug info warn error/ ) {
# #			$js->eval("Envjs.$_=function(x){}");
# #		}
#
# #		$js->eval($JSENV_CODE) or die $@;
#
#                 $code =~ s/(["\\])/\\$1/g;
#                 my $rcode = qq{write(eval("$code"))};
#
#
#
# 		my $out = eval { $js->eval($rcode) };
#
# 		if( $@ ) { print "ERROR: $@"; }
#                 else { print encode_json $out }
# 	}
#
# 	sub ruby_code {
# 		my( $code ) = @_;
# 		local $@;
#
# 		print rb_eval( $code );
# 	}
#
# 	sub php_code {
# 		my( $code ) = @_;
# 		local $@;
#
# 		#warn "PHP - [$code]";
#
# 		my $php = PHP::Interpreter->new;
#
# 		$php->set_output_handler(\ my $output );
#
# 		$php->eval("$code;");
#
# 		print $php->get_output;
#
# 		#warn "ENDING";
#
# 		if( $@ ) { print "ERROR: $@"; }
# 	}
#
# 	sub k20_code {
# 		my( $code ) = @_;
#
# 		$code =~ s/\r?\n//g;
#
#
# 		Language::K20::k20eval( '."\\\\r ' . int(rand(2**31)) . '";' . "\n"); # set random seed
#
# 		Language::K20::k20eval(	$code );
# 	}
#
# 	sub python_code {
# 		my( $code ) = @_;
#
# 		py_eval( $code, 2 );
# 	}
#
# 	sub lua_code {
# 		my( $code ) = @_;
#
# 		#print lua_eval( $code )->();
#
# 		my $ret = lua_eval( $code );
#
# 		print ref $ret ? $ret->() : $ret;
# 	}
#
# 	sub j_code {
# 		my( $code ) = @_;
#
# 		Jplugin::jplugin( $code );
# 	}
