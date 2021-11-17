{ runCommand, git, lib, nixpkgs-fmt }:

runCommand "check-nixpkgs-fmt"
{
  meta.platforms = with lib.platforms; [ linux ];
  buildInputs = [ git nixpkgs-fmt ];
  src = ./..;
}
  ''
    unpackPhase
    cd $sourceRoot
    git init
    git config user.email "devops@iohk.io"
    git config user.name "Hydra CI"
    git config advice.addIgnoredFile false
    git add *
    git commit -m "Hydra CI"
    cp ./scripts/ci/check-nixpkgs-fmt.sh ./scripts/ci/patchedNixpkgsFmt.sh
    patchShebangs ./scripts/ci/patchedNixpkgsFmt.sh
    ./scripts/ci/patchedNixpkgsFmt.sh
    echo $? >> $out
  ''
