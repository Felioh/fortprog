{-# LANGUAGE NamedFieldPuns #-}

-- | cabal-install CLI command: test
--
module Distribution.Client.CmdTest (
    -- * The @test@ CLI and action
    testCommand,
    testAction,

    -- * Internals exposed for testing
    TargetProblem(..),
    selectPackageTargets,
    selectComponentTarget
  ) where

import Distribution.Client.ProjectOrchestration
import Distribution.Client.CmdErrorMessages

import Distribution.Client.Setup
         ( GlobalFlags(..), ConfigFlags(..), ConfigExFlags, InstallFlags )
import qualified Distribution.Client.Setup as Client
import Distribution.Simple.Setup
         ( HaddockFlags, TestFlags(..), BenchmarkFlags(..), fromFlagOrDefault )
import Distribution.Simple.Command
         ( CommandUI(..), usageAlternatives )
import Distribution.Simple.Flag
         ( Flag(..) )
import Distribution.Deprecated.Text
         ( display )
import Distribution.Verbosity
         ( Verbosity, normal )
import Distribution.Simple.Utils
         ( notice, wrapText, die' )

import Control.Monad (when)
import qualified System.Exit (exitSuccess)


testCommand :: CommandUI ( ConfigFlags, ConfigExFlags, InstallFlags
                         , HaddockFlags, TestFlags, BenchmarkFlags
                         )
testCommand = Client.installCommand
  { commandName         = "v2-test"
  , commandSynopsis     = "Run test-suites"
  , commandUsage        = usageAlternatives "v2-test" [ "[TARGETS] [FLAGS]" ]
  , commandDescription  = Just $ \_ -> wrapText $
        "Runs the specified test-suites, first ensuring they are up to "
     ++ "date.\n\n"

     ++ "Any test-suite in any package in the project can be specified. "
     ++ "A package can be specified in which case all the test-suites in the "
     ++ "package are run. The default is to run all the test-suites in the "
     ++ "package in the current directory.\n\n"

     ++ "Dependencies are built or rebuilt as necessary. Additional "
     ++ "configuration flags can be specified on the command line and these "
     ++ "extend the project configuration from the 'cabal.project', "
     ++ "'cabal.project.local' and other files.\n\n"

     ++ "To pass command-line arguments to a test suite, see the "
     ++ "v2-run command."
  , commandNotes        = Just $ \pname ->
        "Examples:\n"
     ++ "  " ++ pname ++ " v2-test\n"
     ++ "    Run all the test-suites in the package in the current directory\n"
     ++ "  " ++ pname ++ " v2-test pkgname\n"
     ++ "    Run all the test-suites in the package named pkgname\n"
     ++ "  " ++ pname ++ " v2-test cname\n"
     ++ "    Run the test-suite named cname\n"
     ++ "  " ++ pname ++ " v2-test cname --enable-coverage\n"
     ++ "    Run the test-suite built with code coverage (including local libs used)\n\n"

     ++ cmdCommonHelpTextNewBuildBeta

  }



-- | The @test@ command is very much like @build@. It brings the install plan
-- up to date, selects that part of the plan needed by the given or implicit
-- test target(s) and then executes the plan.
--
-- Compared to @build@ the difference is that there's also test targets
-- which are ephemeral.
--
-- For more details on how this works, see the module
-- "Distribution.Client.ProjectOrchestration"
--
testAction :: ( ConfigFlags, ConfigExFlags, InstallFlags
              , HaddockFlags, TestFlags, BenchmarkFlags )
           -> [String] -> GlobalFlags -> IO ()
testAction ( configFlags, configExFlags, installFlags
           , haddockFlags, testFlags, benchmarkFlags )
           targetStrings globalFlags = do

    baseCtx <- establishProjectBaseContext verbosity cliConfig OtherCommand

    targetSelectors <- either (reportTargetSelectorProblems verbosity) return
                   =<< readTargetSelectors (localPackages baseCtx) (Just TestKind) targetStrings

    buildCtx <-
      runProjectPreBuildPhase verbosity baseCtx $ \elaboratedPlan -> do

            when (buildSettingOnlyDeps (buildSettings baseCtx)) $
              die' verbosity $
                  "The test command does not support '--only-dependencies'. "
               ++ "You may wish to use 'build --only-dependencies' and then "
               ++ "use 'test'."

            -- Interpret the targets on the command line as test targets
            -- (as opposed to say build or haddock targets).
            targets <- either (reportTargetProblems verbosity failWhenNoTestSuites) return
                     $ resolveTargets
                         selectPackageTargets
                         selectComponentTarget
                         TargetProblemCommon
                         elaboratedPlan
                         Nothing
                         targetSelectors

            let elaboratedPlan' = pruneInstallPlanToTargets
                                    TargetActionTest
                                    targets
                                    elaboratedPlan
            return (elaboratedPlan', targets)

    printPlan verbosity baseCtx buildCtx

    buildOutcomes <- runProjectBuildPhase verbosity baseCtx buildCtx
    runProjectPostBuildPhase verbosity baseCtx buildCtx buildOutcomes
  where
    failWhenNoTestSuites = testFailWhenNoTestSuites testFlags
    verbosity = fromFlagOrDefault normal (configVerbosity configFlags)
    cliConfig = commandLineFlagsToProjectConfig
                  globalFlags configFlags configExFlags
                  installFlags
                  mempty -- ClientInstallFlags, not needed here
                  haddockFlags testFlags benchmarkFlags

-- | This defines what a 'TargetSelector' means for the @test@ command.
-- It selects the 'AvailableTarget's that the 'TargetSelector' refers to,
-- or otherwise classifies the problem.
--
-- For the @test@ command we select all buildable test-suites,
-- or fail if there are no test-suites or no buildable test-suites.
--
selectPackageTargets  :: TargetSelector
                      -> [AvailableTarget k] -> Either TargetProblem [k]
selectPackageTargets targetSelector targets

    -- If there are any buildable test-suite targets then we select those
  | not (null targetsTestsBuildable)
  = Right targetsTestsBuildable

    -- If there are test-suites but none are buildable then we report those
  | not (null targetsTests)
  = Left (TargetProblemNoneEnabled targetSelector targetsTests)

    -- If there are no test-suite but some other targets then we report that
  | not (null targets)
  = Left (TargetProblemNoTests targetSelector)

    -- If there are no targets at all then we report that
  | otherwise
  = Left (TargetProblemNoTargets targetSelector)
  where
    targetsTestsBuildable = selectBuildableTargets
                          . filterTargetsKind TestKind
                          $ targets

    targetsTests          = forgetTargetsDetail
                          . filterTargetsKind TestKind
                          $ targets


-- | For a 'TargetComponent' 'TargetSelector', check if the component can be
-- selected.
--
-- For the @test@ command we just need to check it is a test-suite, in addition
-- to the basic checks on being buildable etc.
--
selectComponentTarget :: SubComponentTarget
                      -> AvailableTarget k -> Either TargetProblem k
selectComponentTarget subtarget@WholeComponent t
  | CTestName _ <- availableTargetComponentName t
  = either (Left . TargetProblemCommon) return $
           selectComponentTargetBasic subtarget t
  | otherwise
  = Left (TargetProblemComponentNotTest (availableTargetPackageId t)
                                        (availableTargetComponentName t))

selectComponentTarget subtarget t
  = Left (TargetProblemIsSubComponent (availableTargetPackageId t)
                                      (availableTargetComponentName t)
                                       subtarget)

-- | The various error conditions that can occur when matching a
-- 'TargetSelector' against 'AvailableTarget's for the @test@ command.
--
data TargetProblem =
     TargetProblemCommon       TargetProblemCommon

     -- | The 'TargetSelector' matches targets but none are buildable
   | TargetProblemNoneEnabled TargetSelector [AvailableTarget ()]

     -- | There are no targets at all
   | TargetProblemNoTargets   TargetSelector

     -- | The 'TargetSelector' matches targets but no test-suites
   | TargetProblemNoTests     TargetSelector

     -- | The 'TargetSelector' refers to a component that is not a test-suite
   | TargetProblemComponentNotTest PackageId ComponentName

     -- | Asking to test an individual file or module is not supported
   | TargetProblemIsSubComponent   PackageId ComponentName SubComponentTarget
  deriving (Eq, Show)

reportTargetProblems :: Verbosity -> Flag Bool -> [TargetProblem] -> IO a
reportTargetProblems verbosity failWhenNoTestSuites problems =
  case (failWhenNoTestSuites, problems) of
    (Flag True, [TargetProblemNoTests _]) ->
      die' verbosity problemsMessage
    (_, [TargetProblemNoTests selector]) -> do
      notice verbosity (renderAllowedNoTestsProblem selector)
      System.Exit.exitSuccess
    (_, _) -> die' verbosity problemsMessage
    where
      problemsMessage = unlines . map renderTargetProblem $ problems

-- | Unless @--test-fail-when-no-test-suites@ flag is passed, we don't
--   @die@ when the target problem is 'TargetProblemNoTests'.
--   Instead, we display a notice saying that no tests have run and
--   indicate how this behaviour was enabled.
renderAllowedNoTestsProblem :: TargetSelector -> String
renderAllowedNoTestsProblem selector =
    "No tests to run for " ++ renderTargetSelector selector

renderTargetProblem :: TargetProblem -> String
renderTargetProblem (TargetProblemCommon problem) =
    renderTargetProblemCommon "run" problem

renderTargetProblem (TargetProblemNoneEnabled targetSelector targets) =
    renderTargetProblemNoneEnabled "test" targetSelector targets

renderTargetProblem (TargetProblemNoTests targetSelector) =
    "Cannot run tests for the target '" ++ showTargetSelector targetSelector
 ++ "' which refers to " ++ renderTargetSelector targetSelector
 ++ " because "
 ++ plural (targetSelectorPluralPkgs targetSelector) "it does" "they do"
 ++ " not contain any test suites."

renderTargetProblem (TargetProblemNoTargets targetSelector) =
    case targetSelectorFilter targetSelector of
      Just kind | kind /= TestKind
        -> "The test command is for running test suites, but the target '"
           ++ showTargetSelector targetSelector ++ "' refers to "
           ++ renderTargetSelector targetSelector ++ "."
           ++ "\n" ++ show targetSelector

      _ -> renderTargetProblemNoTargets "test" targetSelector

renderTargetProblem (TargetProblemComponentNotTest pkgid cname) =
    "The test command is for running test suites, but the target '"
 ++ showTargetSelector targetSelector ++ "' refers to "
 ++ renderTargetSelector targetSelector ++ " from the package "
 ++ display pkgid ++ "."
  where
    targetSelector = TargetComponent pkgid cname WholeComponent

renderTargetProblem (TargetProblemIsSubComponent pkgid cname subtarget) =
    "The test command can only run test suites as a whole, "
 ++ "not files or modules within them, but the target '"
 ++ showTargetSelector targetSelector ++ "' refers to "
 ++ renderTargetSelector targetSelector ++ "."
  where
    targetSelector = TargetComponent pkgid cname subtarget
