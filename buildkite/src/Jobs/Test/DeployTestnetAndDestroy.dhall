let S = ../../Lib/SelectFiles.dhall

let JobSpec = ../../Pipeline/JobSpec.dhall
let Pipeline = ../../Pipeline/Dsl.dhall

let DeployTestnet = ../../Command/DeployTestnet.dhall

let testTestnet = "ci-net"
let dependsOn = [
    { name = "MinaArtifact", key = "mina-docker-image" }
]
let deployDestroyOp = "sleep 60 && terraform destroy -auto-approve"

in Pipeline.build Pipeline.Config::{
  spec =
    JobSpec::{
    dirtyWhen = [
        S.strictlyStart (S.contains "automation/"),
        S.strictlyStart (S.contains "buildkite/src/Jobs/Test/DeployTestnetAndDestroy")
    ],
    path = "Test",
    name = "DeployTestnetAndDestroy"
  },
  steps = [
    DeployTestnet.step testTestnet dependsOn deployDestroyOp
  ]
}
