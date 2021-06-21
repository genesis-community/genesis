To-Do for v2.8.0+

 1. Bosh autoconnection via env vars (v2.8.0)
 2. Credhub add, check, rotate and remove secrets (v2.9.0)
 3. kit-overrides moves into environment file (2.8.x)

		Instead of using kit-overrides.yml to make local changes to the kit, you
		can put kit.overrides.* entries in your environment file.  This works
		better because different env files can use different kits, making a single
		override file less effective or even broken.
		
 4. Use Cepler for pipelines (2.10.0)

		https://github.com/bodymindarts/cepler

 5. Better inheritance system (convension over configuration) (2.8.0? 2.8.x?	 2.9.0?)
		 5.1. Fix how genesis determines what is a env file or not
					
					This is currently done by having a genesis.env or params.env set to
					the same name as the file.  This has long been a contensious issue
					of redundancy.

					The new method would be `<anything>.yml` could be an env file, and
					partial inherited files would be `<partial>-.yml` with the hyphen as
					the last character.

					But to do this in a backwards compatible way, the repo would have to
					be marked as a v2 of genesis config.

					A tool to scan and recommend file renames and edits is needed (and
					ideally has runable output that would do at least the renames)

 6. `genesis update` to get latest genesis command (will be release in v2.7.x) (COMPLETED in 2.7.33)
 7. auto commit after deploy (2.8.x)
 8. `genesis config` to manage .genesis/config file (2.9.x)
 9. `genesis remove` to "undeploy" a given environment.  Preferred over
    `delete` because we're not deleting the environment file. (v2.8.x)


Notes:
  Subkits are removed completely as of 2.8.0
	Kits without new or blueprint are not supported as of 2.8.0

ToDo:
	prereqs hook - what is it?  do we still need it?  any kits actually using
	it? 

	lib/Genesis/Kit.pm:
	-   if (grep { $_ eq $hook } qw/new secrets info addon check prereqs blueprint pre-deploy post-deploy features/) {
	+   if (grep { $_ eq $hook } qw/new secrets info addon check blueprint pre-deploy post-deploy features/) {
