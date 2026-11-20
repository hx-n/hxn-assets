@:buildXml('<compiler id="darwin" exe="clang++" if="macos"><flag value="-Dfdopen=fdopen"/></compiler>')
@:cppFileCode('extern int _hxcpp_argc; extern char **_hxcpp_argv;')
class Host {
	static function main():Void {
		final script = Sys.args()[0];
		if (script == null)
			throw "Host needs a CPPIA script";
		untyped __cpp__("if (_hxcpp_argc > 1) { _hxcpp_argc -= 1; _hxcpp_argv += 1; }");
		cpp.cppia.Host.runFile(script);
	}
}
