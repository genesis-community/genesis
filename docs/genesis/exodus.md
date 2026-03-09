# Exodus Usage Reference Guide

This covers targeting another deployments exodus

## Environment Files
It is proper to allow the environment files to specify overrides:
```
params:
  cf_deployment_env: …
  cf_deployment_type: …
```
These should default to the current environment name and target kit type respectively.

Note that for OCFP architectures this should never be overridden.

## YAML Fragments (& Ops Files)
When referencing in spruce-merge yaml fragments, use meta to set defaults:
```
 meta:
  cf:
    exodus:  (( concat $GENESIS_EXODUS_MOUNT params.cf_deployment_env "/" params.cf_deployment_type ))
    deployment_name: (( concat params.cf_deployment_env "-" params.cf_deployment_type ))

params:
  cf_deployment_env:       (( grab genesis.env )) # assumes same name as cf env
  cf_deployment_type:      cf # for crazy people using an "non-cf" cf
```

## Kit Hooks

```
# Determine exodus target
my $cf_target = sprintf(
  "%s/%s",
  $env->lookup('params.cf_deployment_env',$env->name),
  $env->lookup('params.cf_deployment_type','cf')
)

# Get exodus from target - default to empty hash if not found
my $cf_exodus = $env->exodus_lookup('.',{},$cf_target)

# Error checking and further processing...
```
