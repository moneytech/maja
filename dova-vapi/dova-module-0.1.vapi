/* dova-module-0.1.vapi generated by valac 0.11.0.151-6fc7, do not modify. */

[CCode (cprefix = "Dova", lower_case_cprefix = "dova_")]
namespace Dova {
	[CCode (cheader_filename = "dova-module.h")]
	public class Module : Dova.Object {
		public static Dova.Module? open (Dova.File file);
		public void* symbol (string symbol);
	}
}
