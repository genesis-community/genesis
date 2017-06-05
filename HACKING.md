Hacking on Genesis
==================

A Style Guide
-------------

Genesis is written in Perl, and we adhere to the following style
guidelines:

  - **use_underscore_names** - No camelCaseHere!
  - **no function prototypes** - Use destructuring binds to get
    named arguments out of `@_` in your subs:

    ```
    sub do_thing {
        my ($a, $b, $c) = @_;
    }
    ```

  - **only use core modules** - This eases portability concerns.
    Sometimes, you can't avoid it (as with `JSON::PP`) -- in that
    case, look at the `./pack` script and make sure we can embed
    the non-core module in a distributed script file.
