# Profile data generated by Devel::NYTProf::Reader
# Version
# Author: Adam Kaplan. More information at http://search.cpan.org/~akaplan
# Format: time,calls,time/call,code
0,0,0,sub foo {
0,2,0,my $x;
0,2,0,my $y;
0,2,0,print "in sub foo\n";
0,2,0,for( $x = 1; $x < 100; ++$x ){
0,198,0,bar();
0,198,0,for( $y = 1; $y < 100; ++$y ){
0,0,0,0;
0,198,0,}
0,2,0,}
0,0,0,}
0,0,0,
0,0,0,sub bar {
0,200,0,my $x;
0,200,0,print "in sub bar\n";
0,200,0,for( $x = 1; $x < 100; ++$x ){
0,0,0,1;
0,200,0,}
0,0,0,}
0,0,0,
0,0,0,sub baz {
0,1,0,print "in sub baz\n";
0,2,0,eval { foo();  # counts as two executions
0,1,0,bar(); }; # counts as one execution
0,0,0,}
0,0,0,
0,2,0,eval { bar(); };  # two executions
0,1,0,baz();
0,1,0,eval "foo();";  # one vanilla execution, one eval execution
