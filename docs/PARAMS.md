Herein is documented deployment manifest keys that are reserved
for use by Genesis v2 itself.

## Kit Specification

| Parameter     | Required | Default | Description |
| ------------- | -------- | ------- | ----------- |
| `kit.name`    |   YES    |    -    | The name of the Genesis Kit for this deployment. |
| `kit.version` |   YES    |    -    | The version of the Genesis Kit to use. |
| `kit.subkits` |   YES    |    -    | List of subkits in play. |

## Required Deployment Parameters

These parameters are required to be defined in a deployment
manifest.  If they are not set in a YAML file (or any of its
predecessors), then the merge set that terminates at that file
does not represent a deployment environment.

| Parameter      | Required | Default | Description |
| -------------- | -------- | ------- | ----------- |
| `params.env`   |   YES    |    -    | The name of the environment. |
| `params.vault` |   YES    |    -    | Vault prefix for storing secrets. |
| `params.name`  |   NO     | `params.env`-`kit.name` | The name of the deployment. |
