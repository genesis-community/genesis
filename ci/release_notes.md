# Kit Management Improvements

Added the ability to use the existing prompts and ui elements built into
genesis so that `genesis new` on kits using `hooks/new` script can resemble
those that use `kit.yml`.  This included:

* Adding bash helper functions loaded prior to executing `hooks/new`:
  * `prompt_for <var> <type> <prompt> <options...>`
    * Gives access to the various prompts (line,block,choice,vault,etc)
    * Wraps genesis ui-prompt-for -- see its -h for types and options
    * sets the specified variable to a string or array as deemed
      appropriate
  * `describe <lines...>`
    * Wrapper for explain, prints each argument as a separate line,
      honouring color codes (`#?{...}`)
  * `param_entry <param_var> <variable> [-d [value]] [-a <array values...>]`
    * adds an entry into a params variable for building out the params
      section.  Will use the provided variable for key name and source
      of value, but for arrays, will use the provided array element.
    * Also can provide default (commented out) values with the -d
      <value> or array swith -d -a <array values...>
  * `param_comment <param_var> <lines...>`
    * like `describe`, but adds to the param buildout variable
  * `describe_and_comment <param_var> <lines...>`
    * best of both worlds -- why repeat yourself.

* Added `genesis ui-prompt-for` and `genesis ui-describe`
  * The genesis code behind those bash helpers.  See the -h options for usage
    details if you want to use these outside hooks/new script.

# Improvements

* `params.name` was previously made available to kit developers to know the 
  name of deployments. Now, it can be edited by operators in order to
  set the name of the deployment, whereas before, setting it would simply
  prevent you from deploying at all.
