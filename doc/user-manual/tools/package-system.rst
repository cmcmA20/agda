.. _package-system:

******************
Library Management
******************

Agda has a simple package management system to support working with multiple
libraries in different locations. The central concept is that of a *library*.

.. _use-std-lib:

Example: Using the standard library
-----------------------------------

Before we go into details, here is some quick information for the impatient
on how to tell Agda about the location of the standard library, using the
library management system.

Let's assume you have downloaded the standard library into a directory which we
will refer to by ``AGDA_STDLIB`` (as an absolute path).  A library file
``standard-library.agda-lib`` should exist in this directory, with the
following content:

.. code-block:: none

  name: standard-library
  include: src

To use the standard library by default in your Agda projects, you have
to do two things:

1. Create a file ``AGDA_DIR/libraries`` with the following content:

   .. code-block:: none

     AGDA_STDLIB/standard-library.agda-lib

   (Of course, replace ``AGDA_STDLIB`` by the actual path.)

   The ``AGDA_DIR`` defaults to ``~/.config/agda`` on unix-like systems
   and ``C:\Users\USERNAME\AppData\Roaming\agda`` or similar on Windows.
   (More on ``AGDA_DIR`` below.)

   Remark: The ``libraries`` file informs Agda about the libraries you want it to know
   about.

|

2. Create a file ``AGDA_DIR/defaults`` with the following content:

   .. code-block:: none

     standard-library

   Remark: The ``defaults`` file informs Agda which of the libraries pointed
   to by ``libraries`` should be used by default (i.e. in the default
   include path).

That's the short version, if you want to know more, read on!

Library files
-------------

A library consists of

- a name
- a set of dependencies
- a set of include paths
- a set of default flags

Libraries are defined in ``.agda-lib`` files with the following syntax:

.. code-block:: none

  name: LIBRARY-NAME  -- Comment
  depend: LIB1 LIB2
    LIB3
    LIB4
  include: PATH1
    PATH2
    PATH3
  flags: OPTION1 OPTION2
    OPTION3

Dependencies are library names, not paths to ``.agda-lib`` files, and include
paths are relative to the location of the library-file.

Default flags can be any valid pragma options (see :ref:`Command-line
and pragma options<command-line-pragmas>`).

Each of the four fields is optional.
Naturally, unnamed libraries cannot be depended upon.
But dropping the ``name`` is possible if the library file only serves to list
include paths and/or dependencies of the current project.

.. _The_agda-lib_files_associated_to_a_given_Agda_file:

The ``.agda-lib`` files associated to a given Agda file
-------------------------------------------------------

When a given file is type-checked Agda uses the options from the
``flags`` fields of its library file (if there is such).
If the command-line option :option:`--no-libraries` is used,
then no library file is used.
Otherwise the library file is found in the following way:

- First the file's root directory is found. If the top-level module in
  the file is called ``A.B.C``, then it has to be in the directory
  ``root/A/B`` or ``root\A\B``. The root directory is the directory
  ``root``.

- If ``root`` contains any ``.agda-lib`` files, then the search stops.
  If there is exactly one such file, it is used,
  otherwise an error is raised.

- If ``root`` contains no ``.agda-lib`` files,
  a search is made upwards in the directory hierarchy, and
  the search stops once one or more ``.agda-lib`` files are found in a
  directory.
  If no ``.agda-lib`` files are found all the way to the top of the directory hierarchy,
  then none are used.

Note also that there must not be any ``.agda-lib`` files below the
root, on the path to the Agda file. For instance, if the top-level
module in the Agda file is called ``A.B.C``, and it is in the
directory ``root/A/B``, then there must not be any ``.agda-lib`` files
in ``root/A`` or ``root/A/B``.

Installing libraries
--------------------

To be found by Agda a library file has to be listed (with its full path) in a
``libraries`` file

- ``AGDA_DIR/libraries-VERSION``, or if that doesn't exist
- ``AGDA_DIR/libraries``

where ``VERSION`` is the Agda version (for instance ``2.5.1``). The
:envvar:`AGDA_DIR` defaults to ``~/.config/agda`` on unix-like systems
and ``C:\Users\USERNAME\AppData\Roaming\agda`` or similar on Windows,
and can be overridden by setting the :envvar:`AGDA_DIR` environment
variable.

The :envvar:`AGDA_DIR` will fall-back to ``~/.agda``, if it exists, for
backward compatibility reasons. You can find the precise location of
:envvar:`AGDA_DIR`  by running ``agda --print-agda-app-dir``.

Each line of the libraries file shall be the absolute file system path to
the root of a library, or a comment line starting with ``--`` followed by a space character.

Environment variables in the paths (of the form ``$VAR`` or ``${VAR}``) are
expanded. The location of the ``libraries`` file used can be overridden using
the :option:`--library-file` command line option.

You can find out the precise location of the ``libraries`` file by
calling ``agda -l fjdsk Dummy.agda`` at the command line and looking at the
error message (assuming you don't have a library called ``fjdsk`` installed).

Note that if you want to install a library so that it is used by default,
it must also be listed in the ``defaults`` file (details below).

.. _use-lib:

Using a library
---------------

There are three ways a library gets used:

- You supply the ``--library=LIB`` (or ``-l LIB``) option to Agda. This is
  equivalent to adding a ``-iPATH`` for each of the include paths of ``LIB``
  and its (transitive) dependencies. In this case the current directory is *not*
  implicitly added to the include paths.

- No explicit :option:`--library` option is given, and the current project root
  (of the Agda file that is being loaded) or one of its parent directories
  contains an ``.agda-lib`` file defining a library ``LIB``. This library is
  used as if a ``--library=LIB`` option had been given, except that it is not
  necessary for the library to be listed in the ``AGDA_DIR/libraries`` file.

- No explicit :option:`--library` option, and no ``.agda-lib`` file in the project
  root. In this case the file ``AGDA_DIR/defaults`` is read and all libraries
  listed are added to the path. The ``defaults`` file should contain a list of
  library names, each on a separate line. In this case the current directory is
  *also* added to the path.

  To disable default libraries, you can give the option
  :option:`--no-default-libraries`. To disable using libraries altogether, use the
  :option:`--no-libraries` option.

Default libraries
-----------------

If you want to usually use a variety of libraries, it is simplest to list them
all in the ``AGDA_DIR/defaults`` file.

Each line of the defaults file shall be the name of a library resolvable
using the paths listed in the libraries file.  For example,

   .. code-block:: none

     standard-library
     library2
     library3

where of course ``library2`` and ``library3`` are the libraries you commonly use.
While it is safe to list all your libraries in ``library``, be aware that listing
libraries with name clashes in ``defaults`` can lead to difficulties, and should be
done with care (i.e. avoid it unless you really must).


Version numbers
---------------

Library names can end with a version number (for instance, ``mylib-1.2.3``).
When resolving a library name (given in a :option:`--library` option, or listed as a
default library or library dependency) the following rules are followed:

- If you don't give a version number, any version will do.
- If you give a version number an exact match is required.
- When there are multiple matches an exact match is preferred, and otherwise
  the latest matching version is chosen.

For example, suppose you have the following libraries installed: ``mylib``,
``mylib-1.0``, ``otherlib-2.1``, and ``otherlib-2.3``. In this case, aside from
the exact matches you can also say ``--library=otherlib`` to get
``otherlib-2.3``.

Upgrading
---------

If you are upgrading from a pre 2.5 version of Agda, be aware that you may have
remnants of the previous library management system in your preferences.  In particular,
if you get warnings about ``agda2-include-dirs``, you will need to find where this is
defined.  This may be buried deep in ``.el`` files, whose location is both operating
system and emacs version dependant.
