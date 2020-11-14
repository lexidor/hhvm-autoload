/*
 *  Copyright (c) 2015-present, Facebook, Inc.
 *  All rights reserved.
 *
 *  This source code is licensed under the MIT license found in the
 *  LICENSE file in the root directory of this source tree.
 *
 */

namespace Facebook\AutoloadMap;

use namespace HH\Lib\{Str, Vec};

/** Class to write `autoload.hack`.
 *
 * This includes:
 * - the autoload map
 * - any files to explicitly require
 * - several autogenerated convenience functions
 * - the failure handler
 */
final class Writer {
  private ?vec<string> $files;
  private ?AutoloadMap $map;
  private ?string $root;
  private bool $relativeAutoloadRoot = true;
  private ?string $failureHandler;
  private bool $isDev = true;

  /** Mark whether we're running in development mode.
   *
   * This is only used for `Generated\is_dev()` - the map should already be
   * filtered appropriately.
   */
  public function setIsDev(bool $is_dev): this {
    $this->isDev = $is_dev;
    return $this;
  }

  /** Class to use to handle lookups for items not in the map */
  public function setFailureHandler(?classname<FailureHandler> $handler): this {
    $this->failureHandler = $handler;
    return $this;
  }

  /** Files to explicitly include */
  public function setFiles(vec<string> $files): this {
    $this->files = $files;
    return $this;
  }

  /** The actual autoload map */
  public function setAutoloadMap(AutoloadMap $map): this {
    $this->map = $map;
    return $this;
  }

  /** Set the files and maps from a builder.
   *
   * Convenience function; this is equivalent to calling `setFiles()` and
   * `setAutoloadMap()`.
   */
  public function setBuilder(Builder $builder): this {
    $this->files = $builder->getFiles();
    $this->map = $builder->getAutoloadMap();
    return $this;
  }

  /** Set the root directory of the project */
  public function setRoot(string $root): this {
    $this->root = \realpath($root);
    return $this;
  }

  /** Set whether the autoload map should contain relative or absolute paths */
  public function setRelativeAutoloadRoot(bool $relative): this {
    $this->relativeAutoloadRoot = $relative;
    return $this;
  }

  public function writeToDirectory(string $directory): this {
    $this->writeToFile($directory.'/autoload.hack');

    return $this;
  }

  /** Write the file to disk.
   *
   * You will need to call these first:
   * - `setFiles()`
   * - `setAutoloadMap()`
   * - `setIsDev()`
   */
  public function writeToFile(string $destination_file): this {
    $files = $this->files;
    $map = $this->map;
    $is_dev = $this->isDev;

    if ($files === null) {
      throw new Exception('Call setFiles() before writeToFile()');
    }
    if ($map === null) {
      throw new Exception('Call setAutoloadMap() before writeToFile()');
    }
    if ($is_dev === null) {
      throw new Exception('Call setIsDev() before writeToFile()');
    }
    $is_dev = $is_dev ? 'true' : 'false';

    if ($this->relativeAutoloadRoot) {
      $root = '__DIR__.\'/../\'';
      $requires = Vec\map(
        $files,
        $file ==>
          '__DIR__.'.\var_export('/../'.$this->relativePath($file), true),
      );
    } else {
      $root = \var_export($this->root.'/', true);
      $requires = Vec\map(
        $files,
        $file ==> \var_export($this->root.'/'.$this->relativePath($file), true),
      );
    }

    $requires = \implode(
      "\n",
      Vec\map($requires, $require ==> 'require_once('.$require.');'),
    );

    $map = \array_map(
      ($sub_map): mixed ==> {
        assert($sub_map is KeyedContainer<_, _>);
        return \array_map(
          $path ==> $this->relativePath($path as string),
          $sub_map,
        );
      },
      $map,
    );

    $failure_handler = $this->failureHandler;
    if ($failure_handler !== null) {
      if (\substr($failure_handler, 0, 1) !== '\\') {
        $failure_handler = '\\'.$failure_handler;
      }
    }

    if ($failure_handler !== null) {
      $add_failure_handler = \sprintf(
        "if (%s::isEnabled()) {\n".
        "  \$handler = new %s();\n".
        "  \$map['failure'] = inst_meth(\$handler, 'handleFailure');\n".
        "  \HH\autoload_set_paths(/* HH_FIXME[4110] incorrect hhi */ \$map, Generated\\root());\n".
        "  \$handler->initialize();\n".
        "}",
        $failure_handler,
        $failure_handler,
      );
    } else {
      $add_failure_handler = null;
    }

    $build_id = \var_export(
      \date(\DateTime::ATOM).'!'.\bin2hex(\random_bytes(16)),
      true,
    );

    $map = \var_export($map, true)
      |> \str_replace('array (', 'dict[', $$)
      |> \str_replace(')', ']', $$);

    if ($this->relativeAutoloadRoot) {
      try {
        $autoload_map_typedef = '__DIR__.'.
          \var_export(
            '/../'.$this->relativePath(__DIR__.'/AutoloadMap.hack'),
            true,
          );
      } catch (\Exception $_) {
        // Our unit tests need to load it, and are rooted in the tests/ subdir
        $autoload_map_typedef = \var_export(__DIR__.'/AutoloadMap.hack', true);
      }
    } else {
      $autoload_map_typedef = \var_export(__DIR__.'/AutoloadMap.hack', true);
    }
    $code = <<<EOF
/// Generated file, do not edit by hand ///

namespace Facebook\AutoloadMap\Generated {

function build_id(): string {
  return $build_id;
}

function root(): string {
  return $root;
}

<<__Memoize>>
function is_dev(): bool {
  \$override = \getenv('HH_FORCE_IS_DEV');
  if (\$override === false) {
    return $is_dev;
  }
  return (bool) \$override;
}

function map(): \Facebook\AutoloadMap\AutoloadMap {
  /* HH_IGNORE_ERROR[4110] invalid return type */
  return $map;
}

} // Generated\

namespace Facebook\AutoloadMap\_Private {
  final class GlobalState {
    public static bool \$initialized = false;
  }

  function bootstrap(): void {
    require_once($autoload_map_typedef);
    $requires
  }
}

namespace Facebook\AutoloadMap {

function initialize(): void {
  if (_Private\GlobalState::\$initialized) {
    return;
  }
  _Private\GlobalState::\$initialized = true;
  _Private\bootstrap();
  \$map = Generated\\map();

  \HH\autoload_set_paths(/* HH_FIXME[4110] incorrect hhi */ \$map, Generated\\root());

  $add_failure_handler
}

}
EOF;
    \file_put_contents($destination_file, $code);

    return $this;
  }

  <<__Memoize>>
  private function relativePath(string $path): string {
    $root = $this->root;
    if ($root === null) {
      throw new Exception('Call setRoot() before writeToFile()');
    }
    $path = \realpath($path);
    if (Str\starts_with($path, $root)) {
      return Str\slice($path, Str\length($root) + 1);
    }
    throw new Exception("%s is outside root %s", $path, $root);
  }
}
