use ExtUtils::MakeMaker;

WriteMakefile(
	'NAME' => 'Apache::AXF',
	'VERSION_FROM' => 'AXF.pm',
	'PREREQ_PM' => {'XML::Simple'=>'2.0',
			'XML::LibXML' => '1.53',
			'XML::LibXSLT' => '1.52',
			'Apache::Session::Postgres' => '1.0'},
	'PM' => {'AXF.pm' => '$(INST_LIBDIR)/AXF.pm'},
);
