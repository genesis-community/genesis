# Pipeline Improvements:

* Add support for multi-deployment repos in pipeline
    
  In order to use pipelines, the `.genesis` directory and all the environment
  files had to be at the base of your repo.  However, it is common to have
  your different kit deployments in a single large repo.  This change makes it
  possible to support that configuration, with each subdirectory having its
  own `ci.yml` that specifies the root subdirectory for the pipeline, under
  `pipeline.git.root`.

* Adds caching for `ops/*` and `kit-overrrides.yml`
    
  Note:  This adds caching behaviour to the `ops/*` directory, ensuring that the
  cached values are propagated from previous passed jobs in the pipeline.
  However, each kit will need to detect and make use of them in its blueprint
  hook.
  
  To update kits to do this, they will need to detect the presence of the
  `PREVIOUS_ENV` environment variable, and then the presence of
  `.genesis/cached/$PREVIOUS_ENV/ops/<feature>.yml`

# Bug Fixes:

  * Remove underline when --no-color flag is present in list-kits

