{
  src ? ../.,
  version ? "0.0.0+unknown",
  buildIdentity ? "nix.unknown",
  sourceRevision ? "unknown",
}:

final: _prev:
let
  cleanSrc = final.lib.cleanSourceWith {
    name = "source";
    inherit src;
    filter =
      path: type:
      let
        name = baseNameOf (toString path);
      in
      !(
        type == "directory"
        && builtins.elem name [
          ".dart_tool"
          ".git"
          "build"
          "out"
          "profiling"
          "target"
        ]
      )
      && name != "libflutter_engine.so";
  };
in
{
  denialFlutter = final.callPackage ./flutter-engine.nix { };
  denial = final.callPackage ./package.nix {
    src = cleanSrc;
    inherit version buildIdentity sourceRevision;
  };
}
