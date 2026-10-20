{
  lib,
  stdenv,
  buildDotnetModule,
  dotnet-sdk_10,
  clang,
  autoPatchelfHook,
  zlib,
  icu,
  openssl,
  version,
  src,
}:

buildDotnetModule {
  pname = "meltype-native";
  inherit version src;

  projectFile = "src/Meltype.Mac.Native/Meltype.Mac.Native.csproj";
  dotnet-sdk = dotnet-sdk_10;
  selfContainedBuild = true;
  runtimeId = "linux-x64";
  nativeBuildInputs = [ clang autoPatchelfHook ];
  buildInputs = [ zlib icu openssl stdenv.cc.cc.lib ];
  dotnetFlags = [
    "-p:PublishAot=true"
    "-p:NativeLib=Shared"
    "-p:StripSymbols=true"
    "-p:IlcMaxDegreeOfParallelism=2"
  ];
  executables = [ ];

  postFixup = ''
    patchelf --add-rpath ${lib.makeLibraryPath [ icu openssl ]} "$out/lib/meltype-native/MeltypeNative.so"
  '';
}
