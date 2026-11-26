package hxn.assets.cli;

import hxn.cli.Cli;

/** The hxn command's extension for hxn-assets: `hxn assets build`, `hxn assets catalog` and `hxn assets stage`. **/
class Tool {
	static function main()
		hxn.cli.Plugin.main(new Cli("hxn assets", "Compiles programs with hxn-assets, and catalogs and stages their assets.", [
			new BuildCommand(),
			new CatalogCommand(),
			new StageCommand()
		]));
}
