# Improvements

- Genesis no longer honors BOSH_ENVIRONMENT, because it determines
  its BOSH environment from the params.bosh (if present) or
  params.env (which must be present).  This cuts down on confusion
  and confoundment.
