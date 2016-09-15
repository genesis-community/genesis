# Managing Sites and Environments

|  How do I use Genesis to ... ? | Example |
| ----- | ----- |
| Create a new deployment repo called cloud-foundry | `genesis new deployment cloud-foundry` |
| Create a new deployment repo called cloud-foundry using upstream templates | `genesis new deployment --template cf cloud-foundry` |
| Create a new site | `genesis new site east-coast` |
| Create a new site using infrastructure templates | `genesis new site --template vsphere east-coast` |
| Create a new environment in the east-coast site | `genesis new env east-coast staging` |

# Updating/Operating Environments

| How do I use Genesis to ... ? | Example |
| ----- | ----- |
| Pull in site/global changes to the current environment | `make refresh` |
| Generate a copy of the manifest for the current environment | `make manifest` |
| Deploy via BOSH | `make deploy` |
| Define a new release for environments to use (specifically v241 of cf-release) | `genesis add release cf 241` |
| Configure a site to use the cf-release | `genesis use release cf` |
| Update the version of cf-release used to v242 | `genesis set release cf 242`
| Configure a site to use v3262.12 of the default vsphere stemcell | `genesis use stemcell vsphere 3262.12` |
| Configure a site to use v3262.12 of a specific stemcell | `genesis use stemcell bosh-vsphere-esxi-centos-trusty-go_agent 3262.12` |
| SSH into a BOSH VM | `genesis bosh ssh` |
| Recreate a specific VM | `genesis bosh recreate api_z1/0` |
| Run the smoke-tests BOSH errand | `genesis bosh run errand smoke-tests` |

# Managing Genesis

| How do I use Genesis to ... ? | Example |
| ----- | ----- |
| Update the version of genesis used in a deployment repo | `genesis embed` |
| Update the Makefiles used in the deployment from the current version of genesis | `genesis refresh makefiles` |
| Update the READMEs generated for the deployment using the current version of genesis | `genesis refresh readmes` |
