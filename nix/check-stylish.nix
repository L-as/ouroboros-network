{ runCommand, git, gnugrep, lib, stylish-haskell }:

runCommand "check-stylish"
{
  meta.platforms = with lib.platforms; [ linux ];
  buildInputs = [ git gnugrep stylish-haskell ];
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
    cp ./scripts/ci/check-stylish.sh ./scripts/ci/patchedStylish.sh
    patchShebangs ./scripts/ci/patchedStylish.sh
    ./scripts/ci/patchedStylish.sh
    echo $? >> $out
  ''
