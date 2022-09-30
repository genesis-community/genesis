# Contributing

When contributing to this repository, please first discuss the
change you wish to make via issue, email, or any other method with
the owners of this repository before making a change.

Please note we have a Code of Conduct, please follow it in all
your interactions with the project.

## Pull Request Process

1. Ensure that the software still builds, launches properly, and
   that the test suite still passes.

2. Provide the context of the discussion with the repository
   owners and core team members that lead to the submission of the
   pull request.  This may be as simple as a link to an issue.

3. After review and approval, your Pull Request will be merged by
   a repository owner.

## Test your changes

In order to test your changes, you can use the following development workflow:

- Clone this repo
- Do some changes
- Build a development `genesis` CLI running `make release VERSION=x.y.z`
- Symlink the generated `genesis-x.y.z` (or `genesis-x.y.z-dirty` if you
  didn't commit your code yet) file to `genesis` with
  `ln -s genesis-x.y.z-dirty genesis` (to be done once only)
- Add the current directory in your `PATH` with `export PATH=$PWD:$PATH` (to
  be done only once per shell session) or just copy it to you `~/bin`
  directory if it exists and is on your path
- Go to some deployment directory, check the genesis CLI you'll be using with
  `which genesis` and `genesis version`
- Run the usual `genesis` CLI commands and verify it behaves as expected
