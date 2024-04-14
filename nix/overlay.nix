final: prev:
with final.lib;
with final.haskell.lib;
{
  ops = justStaticExecutables final.haskellPackages.ops;
  haskellPackages = prev.haskellPackages.override (old:
    {
      overrides = composeExtensions (old.overrides or (_: _: { })) (self: super: {
        consul-haskell =
          # Turn off tests for now, they require a running consul
          dontCheck (self.callPackage ../. { });
      });
    }
  );
}
