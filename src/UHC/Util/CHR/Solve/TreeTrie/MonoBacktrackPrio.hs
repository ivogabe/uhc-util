{-# LANGUAGE ScopedTypeVariables, StandaloneDeriving, UndecidableInstances, NoMonomorphismRestriction, MultiParamTypeClasses, TemplateHaskell, FunctionalDependencies #-}

-------------------------------------------------------------------------------------------
--- CHR solver
-------------------------------------------------------------------------------------------

{-|
Under development (as of 20160218).

Solver is:
- Monomorphic, i.e. the solver is polymorph but therefore can only work on 1 type of constraints, rules, etc.
- Knows about variables for which substitutions can be found, substitutions are part of found solutions.
- Backtracking (on variable bindings/substitutions), multiple solution alternatives are explored.
- Found rules are applied in an order described by priorities associated with rules. Priorities can be dynamic, i.e. depend on terms in rules.

See

"A Flexible Search Framework for CHR", Leslie De Koninck, Tom Schrijvers, and Bart Demoen.
http://link.springer.com/10.1007/978-3-540-92243-8_2
-}

module UHC.Util.CHR.Solve.TreeTrie.MonoBacktrackPrio
  ( CHRGlobState(..)
  , emptyCHRGlobState
  
  , CHRBackState(..)
  , emptyCHRBackState
  
  , emptyCHRStore
  
  , CHRMonoBacktrackPrioT
  , MonoBacktrackPrio
  , runCHRMonoBacktrackPrioT
  
  , addRule
  
  , addConstraintAsWork
  
  , SolverResult(..)
  , ppSolverResult
  
  , CHRSolveOpts(..)
  , defaultCHRSolveOpts
  
  , chrSolve
  
  , getSolveTrace
  
{-
  ( CHRStore
  , emptyCHRStore
  
  , chrStoreFromElems
  , chrStoreUnion
  , chrStoreUnions
  , chrStoreSingletonElem
  , chrStoreToList
  , chrStoreElems
  
  , ppCHRStore
  , ppCHRStore'
  
  , SolveStep'(..)
  , SolveStep
  , SolveTrace
  , ppSolveTrace
  
  , SolveState
  , emptySolveState
  , solveStateResetDone
  , chrSolveStateDoneConstraints
  , chrSolveStateTrace
-}
  
  , IsCHRSolvable(..)
{-
  , chrSolve'
  , chrSolve''
  , chrSolveM
  )
-}
  )
  where

import           UHC.Util.CHR.Base
import           UHC.Util.CHR.Key
import           UHC.Util.CHR.Rule
import           UHC.Util.CHR.Solve.TreeTrie.Internal.Shared
import           UHC.Util.Substitutable
import           UHC.Util.VarLookup
import           UHC.Util.VarMp
import           UHC.Util.AssocL
import           UHC.Util.TreeTrie as TreeTrie
import qualified Data.Set as Set
import qualified Data.Map as Map
import qualified Data.IntMap.Strict as IntMap
import qualified Data.Sequence as Seq
import           Data.List as List
import           Data.Typeable
-- import           Data.Data
import           Data.Maybe
import           UHC.Util.Pretty as Pretty
import           UHC.Util.Serialize
import           Control.Monad
import           Control.Monad.Except
import           Control.Monad.State.Strict
import           UHC.Util.Utils
import           UHC.Util.Lens
import           Control.Monad.LogicState

import           UHC.Util.Debug

-------------------------------------------------------------------------------------------
--- A CHR as stored
-------------------------------------------------------------------------------------------

-- | Index into table of CHR's, allowing for indirection required for sharing of rules by search for different constraints in the head
type CHRInx = Int

-- | Index into rule and head constraint
data CHRConstraintInx =
  CHRConstraintInx -- {-# UNPACK #-}
    { chrciInx :: !CHRInx
    , chrciAt  :: !Int
    }
  deriving Show

instance PP CHRConstraintInx where
  pp (CHRConstraintInx i j) = i >|< "." >|< j

-- | A CHR as stored in a CHRStore, requiring additional info for efficiency
data StoredCHR c g bp p
  = StoredCHR
      { _storedHeadKeys  :: ![CHRTrieKey c]                        -- ^ the keys corresponding to the head of the rule
      , _storedChrRule   :: !(Rule c g bp p)                          -- ^ the rule
      , _storedChrInx    :: !CHRInx                                -- ^ index of constraint for which is keyed into store
      -- , storedKeys      :: ![Maybe (CHRKey c)]                  -- ^ keys of all constraints; at storedChrInx: Nothing
      -- , storedIdent     :: !(UsedByKey c)                       -- ^ the identification of a CHR, used for propagation rules (see remark at begin)
      }
  deriving (Typeable)

mkLabel ''StoredCHR

type instance TTKey (StoredCHR c g bp p) = TTKey c

{-
instance (TTKeyable (Rule c g bp p)) => TTKeyable (StoredCHR c g bp p) where
  toTTKey' o schr = toTTKey' o $ storedChrRule schr

-- | The size of the simplification part of a CHR
storedSimpSz :: StoredCHR c g bp p -> Int
storedSimpSz = ruleSimpSz . storedChrRule
{-# INLINE storedSimpSz #-}
-}

-- | A CHR store is a trie structure
data CHRStore cnstr guard bprio prio
  = CHRStore
      { _chrstoreTrie    :: CHRTrie' cnstr [CHRConstraintInx]                       -- ^ map from the search key of a rule to the index into tabl
      , _chrstoreTable   :: IntMap.IntMap (StoredCHR cnstr guard bprio prio)      -- ^ (possibly multiple) rules for a key
      }
  deriving (Typeable)

mkLabel ''CHRStore

emptyCHRStore :: CHRStore cnstr guard bprio prio
emptyCHRStore = CHRStore TreeTrie.empty IntMap.empty

-------------------------------------------------------------------------------------------
--- Store holding work, split up in global and backtrackable part
-------------------------------------------------------------------------------------------

type WorkInx = WorkTime

data WorkStore cnstr
  = WorkStore
      { _wkstoreTrie     :: CHRTrie' cnstr [WorkInx]                -- ^ map from the search key of a constraint to index in table
      , _wkstoreTable    :: IntMap.IntMap (Work cnstr)      -- ^ all the work ever entered
      }
  deriving (Typeable)

mkLabel ''WorkStore

emptyWorkStore :: WorkStore cnstr
emptyWorkStore = WorkStore TreeTrie.empty IntMap.empty

data WorkQueue
  = WorkQueue
      { _wkqueueSet      :: Set.Set WorkInx                -- ^ cached/derived from queue: as set (for check on being in the queue)
      -- , _wkqueueQueue    :: Seq.Seq WorkInx                -- ^ queue holding the work to be done, as index into work table
      }
  deriving (Typeable)

mkLabel ''WorkQueue

emptyWorkQueue :: WorkQueue
emptyWorkQueue = WorkQueue Set.empty -- Seq.empty

-------------------------------------------------------------------------------------------
--- Index into CHR and head constraint
-------------------------------------------------------------------------------------------


-------------------------------------------------------------------------------------------
--- A matched combi of chr and work
-------------------------------------------------------------------------------------------

-- | Already matched combi of chr and work
data MatchedCombi' c w =
  MatchedCombi
    { mcCHR      :: !c              -- ^ the CHR
    , mcWork     :: ![w]            -- ^ the work matched for this CHR
    }
  deriving (Eq, Ord)

instance Show (MatchedCombi' c w) where
  show _ = "MatchedCombi"

instance (PP c, PP w) => PP (MatchedCombi' c w) where
  pp (MatchedCombi c ws) = ppParensCommas [pp c, ppBracketsCommas ws]

type MatchedCombi = MatchedCombi' CHRInx WorkInx

-------------------------------------------------------------------------------------------
--- Solver reduction step
-------------------------------------------------------------------------------------------

-- | Description of 1 chr reduction step taken by the solver
data SolverReductionStep' c w
  = SolverReductionStep
      { slvredMatchedCombi        :: !(MatchedCombi' c w)
      , slvredNewWork             :: !(Map.Map ConstraintSolvesVia [w])
      }
  | SolverReductionDBG PP_Doc

type SolverReductionStep = SolverReductionStep' CHRInx WorkInx

instance Show (SolverReductionStep' c w) where
  show _ = "SolverReductionStep"

instance {-# OVERLAPPABLE #-} (PP c, PP w) => PP (SolverReductionStep' c w) where
  pp (SolverReductionStep (MatchedCombi ci ws) wns) = "STEP" >#< ci >-< indent 2 ("+" >#< ppBracketsCommas ws >-< "-> (new)" >#< (ppAssocL $ Map.toList $ Map.map ppBracketsCommas wns)) -- (ppBracketsCommas wns >-< ppBracketsCommas wnbs)
  pp (SolverReductionDBG p) = "DBG" >#< p

instance (PP w) => PP (SolverReductionStep' Int w) where
  pp (SolverReductionStep (MatchedCombi ci ws) wns) = ci >#< "+" >#< ppBracketsCommas ws >#< "-> (new)" >#< (ppAssocL $ Map.toList $ Map.map ppBracketsCommas wns) -- (ppBracketsCommas wns >-< ppBracketsCommas wnbs)
  pp (SolverReductionDBG p) = "DBG" >#< p

-------------------------------------------------------------------------------------------
--- The CHR monad, state, etc. Used to interact with store and solver
-------------------------------------------------------------------------------------------

-- | Global state
data CHRGlobState cnstr guard bprio prio subst
  = CHRGlobState
      { _chrgstStore                 :: !(CHRStore cnstr guard bprio prio)                     -- ^ Actual database of rules, to be searched
      , _chrgstNextFreeRuleInx       :: !CHRInx                                          -- ^ Next free rule identification, used by solving to identify whether a rule has been used for a constraint.
                                                                                         --   The numbering is applied to constraints inside a rule which can be matched.
      -- , _chrgstNextFreshVarId        :: !(ExtrValVarKey (Rule cnstr guard bprio prio))         -- ^ The next free id used for a fresh variable
      , _chrgstWorkStore             :: !(WorkStore cnstr)                               -- ^ Actual database of solvable constraints
      , _chrgstNextFreeWorkInx       :: !WorkTime                                        -- ^ Next free work/constraint identification, used by solving to identify whether a rule has been used for a constraint.
      , _chrgstTrace                 :: SolveTrace' cnstr (StoredCHR cnstr guard bprio prio) subst
      }
  deriving (Typeable)

mkLabel ''CHRGlobState

emptyCHRGlobState :: {- Num (ExtrValVarKey c) => -} CHRGlobState c g b p s
emptyCHRGlobState = CHRGlobState emptyCHRStore 0 emptyWorkStore initWorkTime emptySolveTrace

-- | Backtrackable state
data CHRBackState cnstr bprio subst
  = CHRBackState
      { _chrbstBacktrackPrio         :: !bprio                           -- ^ the current backtrack prio the solver runs on
      , _chrbstSolveSubst            :: !subst                           -- ^ subst for variable bindings found during solving, not for the ones binding rule metavars during matching but for the user ones (in to be solved constraints)
      , _chrbstRuleWorkQueue         :: !WorkQueue                       -- ^ work queue for rule matching
      , _chrbstSolveQueue            :: !WorkQueue                       -- ^ solve queue, constraints which are not solved by rule matching but with some domain specific solver, yielding variable subst constributing to backtrackable bindings
      , _chrbstResidualQueue         :: [WorkInx]                        -- ^ residual queue, constraints which are residual, no need to solve, etc
      , _chrbstLeftWorkQueue         :: [WorkInx]                        -- ^ left over work queue, constraints which could not be solved
      , _chrbstMatchedCombis         :: !(Set.Set MatchedCombi)          -- ^ all combis of chr + work which were reduced, to prevent this from happening a second time (when propagating)
      , _chrbstReductionSteps        :: [SolverReductionStep]
      }
  deriving (Typeable)

mkLabel ''CHRBackState

emptyCHRBackState :: (CHREmptySubstitution s, Bounded bp) => CHRBackState c bp s
emptyCHRBackState = CHRBackState minBound chrEmptySubst emptyWorkQueue emptyWorkQueue [] [] Set.empty []

-- | Monad for CHR, taking from 'LogicStateT' the state and backtracking behavior
type CHRMonoBacktrackPrioT cnstr guard bprio prio subst env m
  = LogicStateT (CHRGlobState cnstr guard bprio prio subst) (CHRBackState cnstr bprio subst) m

-- | All required behavior, as class alias
class ( IsCHRSolvable env cnstr guard bprio prio subst
      , Monad m
      , Ord (TTKey cnstr)
      , Ord prio
      , TTKeyable cnstr
      -- , CHREmptySubstitution subst
      -- , CHRMatchable env cnstr subst
      -- , CHRCheckable env guard subst
      -- , VarLookupCmb subst subst
      -- , TTKey cnstr ~ TrTrKey cnstr
      , MonadIO m -- for debugging
      ) => MonoBacktrackPrio cnstr guard bprio prio subst env m
         | cnstr guard bprio prio subst -> env

runCHRMonoBacktrackPrioT
  :: Monad m
     => CHRGlobState cnstr guard bprio prio subst
     -> CHRBackState cnstr bprio subst
     -- -> CHRPrioEvaluatableVal bprio
     -> CHRMonoBacktrackPrioT cnstr guard bprio prio subst env m a
     -> m [a]
runCHRMonoBacktrackPrioT gs bs {- bp -} m = observeAllT (gs, bs {- _chrbstBacktrackPrio=bp -}) m

getSolveTrace :: (PP c, PP g, PP bp, MonoBacktrackPrio c g bp p s e m) => CHRMonoBacktrackPrioT c g bp p s e m PP_Doc
getSolveTrace = fmap (ppSolveTrace . reverse) $ getl $ fstl ^* chrgstTrace

-------------------------------------------------------------------------------------------
--- CHR store, API for adding rules
-------------------------------------------------------------------------------------------

{-
-- | Combine lists of stored CHRs by concat, adapting their identification nr to be unique
cmbStoredCHRs :: [StoredCHR c g bp p] -> [StoredCHR c g bp p] -> [StoredCHR c g bp p]
cmbStoredCHRs s1 s2
  = map (\s@(StoredCHR {storedIdent=(k,nr)}) -> s {storedIdent = (k,nr+l)}) s1 ++ s2
  where l = length s2
-}

instance Show (StoredCHR c g bp p) where
  show _ = "StoredCHR"

ppStoredCHR :: (PP (TTKey c), PP c, PP g, PP bp, PP p) => StoredCHR c g bp p -> PP_Doc
ppStoredCHR c@(StoredCHR {})
  = ppParensCommas (_storedHeadKeys c)
    >-< _storedChrRule c
    >-< indent 2
          (ppParensCommas
            [ pp $ _storedChrInx c
            -- , pp $ storedSimpSz c
            -- , "keys" >#< (ppBracketsCommas $ map (maybe (pp "?") ppTreeTrieKey) $ storedKeys c)
            -- , "ident" >#< ppParensCommas [ppTreeTrieKey idKey,pp idSeqNr]
            ])

instance (PP (TTKey c), PP c, PP g, PP bp, PP p) => PP (StoredCHR c g bp p) where
  pp = ppStoredCHR

{-
-- | Convert from list to store
chrStoreFromElems :: (TTKeyable c, Ord (TTKey c), TTKey c ~ TrTrKey c) => [Rule c g bp p] -> CHRStore c g b p
chrStoreFromElems chrs
  = mkCHRStore
    $ chrTrieFromListByKeyWith cmbStoredCHRs
        [ (k,[StoredCHR chr i ks' (concat ks,0)])
        | chr <- chrs
        , let cs = ruleHead chr
              simpSz = ruleSimpSz chr
              ks = map chrToKey cs
        , (c,k,i) <- zip3 cs ks [0..]
        , let (ks1,(_:ks2)) = splitAt i ks
              ks' = map Just ks1 ++ [Nothing] ++ map Just ks2
        ]
-}

-- | Add a rule as a CHR
addRule :: MonoBacktrackPrio c g bp p s e m => Rule c g bp p -> CHRMonoBacktrackPrioT c g bp p s e m ()
addRule chr = do
    i <- modifyAndGet (fstl ^* chrgstNextFreeRuleInx) $ \i -> (i, i + 1)
    let ks = map chrToKey $ ruleHead chr
    fstl ^* chrgstStore ^* chrstoreTable =$: IntMap.insert i (StoredCHR ks chr i)
    fstl ^* chrgstStore ^* chrstoreTrie =$: \t ->
      foldr (TreeTrie.unionWith (++)) t [ TreeTrie.singleton k [CHRConstraintInx i j] | (k,c,j) <- zip3 ks (ruleHead chr) [0..] ]
    return ()

-- | Add work to the rule work queue
addWorkToRuleWorkQueue :: MonoBacktrackPrio c g bp p s e m => WorkInx -> CHRMonoBacktrackPrioT c g bp p s e m ()
addWorkToRuleWorkQueue i = do
    -- sndl ^* chrbstRuleWorkQueue ^* wkqueueQueue =$: (Seq.|> i)
    sndl ^* chrbstRuleWorkQueue ^* wkqueueSet =$: (Set.insert i)

-- | Add work to the solve queue
addWorkToSolveQueue :: MonoBacktrackPrio c g bp p s e m => WorkInx -> CHRMonoBacktrackPrioT c g bp p s e m ()
addWorkToSolveQueue i = do
    -- sndl ^* chrbstRuleWorkQueue ^* wkqueueQueue =$: (Seq.|> i)
    sndl ^* chrbstSolveQueue ^* wkqueueSet =$: (Set.insert i)

-- | Split off work from the solve work queue, possible none left
splitWorkFromSolveQueue :: MonoBacktrackPrio c g bp p s e m => CHRMonoBacktrackPrioT c g bp p s e m (Maybe (WorkInx))
splitWorkFromSolveQueue = do
    wq <- getl $ sndl ^* chrbstSolveQueue ^* wkqueueSet
    case Set.minView wq of
      Nothing ->
          return Nothing
      Just (workInx, wq') -> do
          sndl ^* chrbstSolveQueue ^* wkqueueSet =: wq'
          return $ Just (workInx)

-- | Remove work from the work queue
deleteWorkFromQueue :: MonoBacktrackPrio c g bp p s e m => [WorkInx] -> CHRMonoBacktrackPrioT c g bp p s e m ()
deleteWorkFromQueue is = do
    -- sndl ^* chrbstRuleWorkQueue ^* wkqueueQueue =$: (Seq.|> i)
    sndl ^* chrbstRuleWorkQueue ^* wkqueueSet =$: (\s -> foldr (Set.delete) s is)

-- | Extract the active work in the queue
activeInQueue :: MonoBacktrackPrio c g bp p s e m => CHRMonoBacktrackPrioT c g bp p s e m (Set.Set WorkInx)
activeInQueue = getl $ sndl ^* chrbstRuleWorkQueue ^* wkqueueSet

-- | Split off work from the work queue, possible none left
splitWorkFromQueue :: MonoBacktrackPrio c g bp p s e m => CHRMonoBacktrackPrioT c g bp p s e m (Maybe (WorkInx, Set.Set WorkInx))
splitWorkFromQueue = do
    -- wq <- getl $ sndl ^* chrbstRuleWorkQueue ^* wkqueueQueue
    wq <- getl $ sndl ^* chrbstRuleWorkQueue ^* wkqueueSet
    case Set.minView wq of
      -- If no more work, ready
      -- Seq.EmptyL -> 
      Nothing ->
          return Nothing
      
      -- There is work in the queue
      -- workInx Seq.:< wq' -> do
      Just (workInx, wq') -> do
          -- sndl ^* chrbstRuleWorkQueue ^* wkqueueQueue =: wq'
          sndl ^* chrbstRuleWorkQueue ^* wkqueueSet =: wq'
          -- sndl ^* chrbstRuleWorkQueue ^* wkqueueSet =$: (Set.delete workInx)
          return $ Just (workInx, wq')

-- | Add a constraint to be solved or residualised
addConstraintAsWork :: MonoBacktrackPrio c g bp p s e m => c -> CHRMonoBacktrackPrioT c g bp p s e m (ConstraintSolvesVia, WorkInx)
addConstraintAsWork c = do
    let via = cnstrSolvesVia c
        addw i w = do
          fstl ^* chrgstWorkStore ^* wkstoreTable =$: IntMap.insert i w
          return (via,i)
    case via of
        ConstraintSolvesVia_Rule -> do
            i <- fresh
            fstl ^* chrgstWorkStore ^* wkstoreTrie =$: TreeTrie.insertByKeyWith (++) k [i]
            addWorkToRuleWorkQueue i
            addw i $ Work k c i
          where k = chrToWorkKey c
        ConstraintSolvesVia_Solve -> do
            i <- fresh
            addWorkToSolveQueue i
            addw i $ Work_Solve c
        ConstraintSolvesVia_Residual -> do
            i <- fresh
            sndl ^* chrbstResidualQueue =$: (i :)
            addw i $ Work_Residue c
        ConstraintSolvesVia_Fail -> do
            -- fail right away
            mzero
  where
    fresh = modifyAndGet (fstl ^* chrgstNextFreeWorkInx) $ \i -> (i, i + 1)
{-

chrStoreSingletonElem :: (TTKeyable c, Ord (TTKey c), TTKey c ~ TrTrKey c) => Rule c g bp p -> CHRStore c g b p
chrStoreSingletonElem x = chrStoreFromElems [x]

chrStoreUnion :: (Ord (TTKey c)) => CHRStore c g b p -> CHRStore c g b p -> CHRStore c g b p
chrStoreUnion cs1 cs2 = mkCHRStore $ chrTrieUnionWith cmbStoredCHRs (chrstoreTrie cs1) (chrstoreTrie cs2)
{-# INLINE chrStoreUnion #-}

chrStoreUnions :: (Ord (TTKey c)) => [CHRStore c g b p] -> CHRStore c g b p
chrStoreUnions []  = emptyCHRStore
chrStoreUnions [s] = s
chrStoreUnions ss  = foldr1 chrStoreUnion ss
{-# INLINE chrStoreUnions #-}

chrStoreToList :: (Ord (TTKey c)) => CHRStore c g b p -> [(CHRKey c,[Rule c g bp p])]
chrStoreToList cs
  = [ (k,chrs)
    | (k,e) <- chrTrieToListByKey $ chrstoreTrie cs
    , let chrs = [chr | (StoredCHR {storedChrRule = chr, storedChrInx = 0}) <- e]
    , not $ Prelude.null chrs
    ]

chrStoreElems :: (Ord (TTKey c)) => CHRStore c g b p -> [Rule c g bp p]
chrStoreElems = concatMap snd . chrStoreToList

ppCHRStore :: (PP c, PP g, PP p, Ord (TTKey c), PP (TTKey c)) => CHRStore c g b p -> PP_Doc
ppCHRStore = ppCurlysCommasBlock . map (\(k,v) -> ppTreeTrieKey k >-< indent 2 (":" >#< ppBracketsCommasBlock v)) . chrStoreToList

ppCHRStore' :: (PP c, PP g, PP p, Ord (TTKey c), PP (TTKey c)) => CHRStore c g b p -> PP_Doc
ppCHRStore' = ppCurlysCommasBlock . map (\(k,v) -> ppTreeTrieKey k >-< indent 2 (":" >#< ppBracketsCommasBlock v)) . chrTrieToListByKey . chrstoreTrie

-}

-------------------------------------------------------------------------------------------
--- Solver result
-------------------------------------------------------------------------------------------

-- | Solver solution
data SolverResult subst =
  SolverResult
    { slvresSubst                 :: subst                            -- ^ global found variable bindings
    , slvresResidualCnstr         :: [WorkInx]                        -- ^ constraints which are residual, no need to solve, etc, leftover when ready, taken from backtrack state
    , slvresWorkCnstr             :: [WorkInx]                        -- ^ constraints which are still unsolved, taken from backtrack state
    , slvresReductionSteps        :: [SolverReductionStep]            -- ^ how did we get to the result (taken from the backtrack state when a result is given back)
    }

{-
emptySolverResult :: CHREmptySubstitution s => SolverResult s
emptySolverResult = SolverResult chrEmptySubst [] [] []
-}

-- | Succesful return, solution is found
slvSucces :: MonoBacktrackPrio c g bp p s e m => CHRMonoBacktrackPrioT c g bp p s e m (SolverResult s)
slvSucces = do
    bst <- getl $ sndl
    return $ SolverResult
      { slvresSubst = bst ^. chrbstSolveSubst
      , slvresResidualCnstr = reverse $ bst ^. chrbstResidualQueue
      , slvresWorkCnstr = reverse $ bst ^. chrbstLeftWorkQueue
      , slvresReductionSteps = reverse $ bst ^. chrbstReductionSteps
      }

-------------------------------------------------------------------------------------------
--- Solver trace
-------------------------------------------------------------------------------------------

{-
type SolveStep  c g b p s = SolveStep'  c (Rule c g bp p) s
type SolveTrace c g b p s = SolveTrace' c (Rule c g bp p) s
-}

-------------------------------------------------------------------------------------------
--- Cache for maintaining which WorkKey has already had a match
-------------------------------------------------------------------------------------------

{-
-- type SolveMatchCache c g b p s = Map.Map (CHRKey c) [((StoredCHR c g bp p,([WorkKey c],[Work c])),s)]
-- type SolveMatchCache c g b p s = Map.Map (WorkKey c) [((StoredCHR c g bp p,([WorkKey c],[Work c])),s)]
type SolveMatchCache c g b p s = SolveMatchCache' c (StoredCHR c g bp p) s
-}

-------------------------------------------------------------------------------------------
--- Solve state
-------------------------------------------------------------------------------------------

{-
type SolveState c g b p s = SolveState' c (Rule c g bp p) (StoredCHR c g bp p) s
-}

-------------------------------------------------------------------------------------------
--- Solver utils
-------------------------------------------------------------------------------------------

lkupWork :: MonoBacktrackPrio c g bp p s e m => WorkInx -> CHRMonoBacktrackPrioT c g bp p s e m (Work c)
lkupWork i = fmap (IntMap.findWithDefault (panic "MBP.wkstoreTable.lookup") i) $ getl $ fstl ^* chrgstWorkStore ^* wkstoreTable

lkupChr :: MonoBacktrackPrio c g bp p s e m => CHRInx -> CHRMonoBacktrackPrioT c g bp p s e m (StoredCHR c g bp p)
lkupChr  i = fmap (IntMap.findWithDefault (panic "MBP.chrSolve.chrstoreTable.lookup") i) $ getl $ fstl ^* chrgstStore ^* chrstoreTable

-- | Convert
cvtSolverReductionStep :: MonoBacktrackPrio c g bp p s e m => SolverReductionStep' CHRInx WorkInx -> CHRMonoBacktrackPrioT c g bp p s e m (SolverReductionStep' (StoredCHR c g bp p) (Work c))
cvtSolverReductionStep (SolverReductionStep mc nw) = do
    mc  <- cvtMC mc
    nw  <- fmap Map.fromList $ forM (Map.toList nw) $ \(via,i) -> do
             i <- forM i lkupWork
             return (via, i)
    return $ SolverReductionStep mc nw
  where
    cvtMC (MatchedCombi {mcCHR = c, mcWork = ws}) = do
      c'  <- lkupChr c
      ws' <- forM ws lkupWork
      return $ MatchedCombi c' ws'
cvtSolverReductionStep (SolverReductionDBG pp) = return (SolverReductionDBG pp)

-- | PP result
ppSolverResult
  :: ( MonoBacktrackPrio c g bp p s e m
     , PP s
     ) => Bool
       -> SolverResult s
       -> CHRMonoBacktrackPrioT c g bp p s e m PP_Doc
ppSolverResult inclSteps (SolverResult {slvresSubst = s, slvresResidualCnstr = ris, slvresWorkCnstr = wis, slvresReductionSteps = steps}) = do
    rs <- forM ris $ \i -> lkupWork i >>= return . pp . workCnstr
    ws <- forM wis $ \i -> lkupWork i >>= return . pp . workCnstr
    ss <- if inclSteps
      then forM steps $ \step -> cvtSolverReductionStep step >>= (return . pp)
      else return [pp "Only included when asked for"]
    return $ 
          "Subst"   >-< indent 2 s
      >-< "Residue" >-< indent 2 (vlist rs)
      >-< "Work"    >-< indent 2 (vlist ws)
      >-< "Steps"   >-< indent 2 (vlist ss)

-------------------------------------------------------------------------------------------
--- Solver: required instances
-------------------------------------------------------------------------------------------

-- | (Class alias) API for solving requirements
class ( IsCHRConstraint env c s
      , IsCHRGuard env g s
      , IsCHRBacktrackPrio env bp s
      , IsCHRPrio env p s
      -- , Bounded bp
      -- , IsCHRBuiltin env b s
      -- , VarLookupCmb s s
      -- , VarUpdatable s s
      -- , CHREmptySubstitution s
      , TrTrKey c ~ TTKey c
      , PP (SubstVarKey s)
      ) => IsCHRSolvable env c g bp p s

-------------------------------------------------------------------------------------------
--- Solver: Intermediate structures
-------------------------------------------------------------------------------------------

-- | Intermediate Solver structure
data FoundChr c g bp p
  = FoundChr
      { foundChrInx             :: !CHRInx
      , foundChrChr             :: !(StoredCHR c g bp p)
      , foundChrCnstr           :: ![WorkInx]
      }

-- | Intermediate Solver structure
data FoundWorkInx c g bp p
  = FoundWorkInx
      { foundWorkInxInx         :: !CHRConstraintInx
      , foundWorkInxChr         :: !(StoredCHR c g bp p)
      , foundWorkInxWorkInxs    :: ![[WorkInx]]
      }

-- | Intermediate Solver structure: all matched combis with their body alternatives + backtrack priorities
data FoundSlvMatch c g bp p s
  = FoundSlvMatch
      { foundSlvMatchMbPrio         :: !(Maybe p)
      , foundSlvMatchSubst          :: !s
      , foundSlvMatchWaitForVars    :: !(Set.Set (SubstVarKey s))
      , foundSlvMatchBodyAlts       :: ![(CHRPrioEvaluatableVal bp, RuleBodyAlt c bp)]
      }

instance Show (FoundSlvMatch c g bp p s) where
  show _ = "FoundSlvMatch"

instance (PP s, PP p, PP c, PP bp, PP (SubstVarKey s), PP (CHRPrioEvaluatableVal bp)) => PP (FoundSlvMatch c g bp p s) where
  pp (FoundSlvMatch {foundSlvMatchMbPrio=p, foundSlvMatchSubst=s, foundSlvMatchWaitForVars=ws, foundSlvMatchBodyAlts=as}) = "@" >|< p >#< ws >#< s >-< vlist as

-- | Intermediate Solver structure: all matched combis with their backtrack prioritized body alternatives
data FoundWorkMatch c g bp p s
  = FoundWorkMatch
      { foundWorkMatchInx       :: !CHRConstraintInx
      , foundWorkMatchChr       :: !(StoredCHR c g bp p)
      , foundWorkMatchWorkInx   :: ![WorkInx]
      , foundWorkMatchSlvMatch  :: !(Maybe (FoundSlvMatch c g bp p s))
      }

-------------------------------------------------------------------------------------------
--- Solver options
-------------------------------------------------------------------------------------------

-- | Solve specific options
data CHRSolveOpts
  = CHRSolveOpts
      { chrslvOptSucceedOnLeftoverWork	:: !Bool		-- ^ left over unresolvable (non residue) work is also a succesful result
      }

defaultCHRSolveOpts :: CHRSolveOpts
defaultCHRSolveOpts
  = CHRSolveOpts
      { chrslvOptSucceedOnLeftoverWork	= False
      }

-------------------------------------------------------------------------------------------
--- Solver
-------------------------------------------------------------------------------------------

-- | (Under dev) solve
chrSolve
  :: -- forall c g bp p s e m .
     ( MonoBacktrackPrio c g bp p s e m
     , PP s
     ) => CHRSolveOpts
       -> e
       -> CHRMonoBacktrackPrioT c g bp p s e m (SolverResult s)
chrSolve opts env = slv
  where
    -- solve
    slv = do
        mbSlvWk <- splitWorkFromSolveQueue
        case mbSlvWk of
          -- There is work in the solve work queue
          Just (workInx) -> do
              work <- lkupWork workInx
              subst <- getl $ sndl ^* chrbstSolveSubst
              let mbSlv = flip chrmatcherRun subst $ chrBuiltinSolveM env $ workCnstr work
              case mbSlv of
                Just (s,_) -> sndl ^* chrbstSolveSubst =$: (s |+>)
                _          -> sndl ^* chrbstResidualQueue =$: (workInx :)

              -- debug info
              sndl ^* chrbstReductionSteps =$: (SolverReductionDBG
                (    "solve wk" >#< work
                 >-< "match" >#< mbSlv
                ) :)

              -- just continue with next work
              slv

          -- If no more solve work, continue with normal work
          Nothing -> do
              activeWk <- activeInQueue
              visitedChrWkCombis <- getl $ sndl ^* chrbstMatchedCombis
              mbWk <- splitWorkFromQueue
              case mbWk of
                -- If no more work, ready
                Nothing -> slvSucces
      
                -- There is work in the queue
                Just (workInx, _) -> do
                    -- lookup the work
                    work <- lkupWork workInx
          
                    -- find all matching chrs for the work
                    foundChrInxs <- fmap (concat . TreeTrie.lookupResultToList . TreeTrie.lookupPartialByKey TTL_WildInTrie (workKey work))
                      $ getl $ fstl ^* chrgstStore ^* chrstoreTrie
                    let foundChrGroupedInxs = Map.unionsWith (++) $ map (\(CHRConstraintInx i j) -> Map.singleton i [j]) foundChrInxs
                    foundChrs <- forM (Map.toList foundChrGroupedInxs) $ \(chrInx,rlInxs) -> lkupChr chrInx >>= \chr -> return $ FoundChr chrInx chr rlInxs

                    -- found chrs for the work correspond to 1 single position in the head, find all combinations with work in the queue
                    foundWorkInxs <- sequence [ fmap (FoundWorkInx (CHRConstraintInx ci i) c) $ slvCandidate activeWk visitedChrWkCombis (workKey work) c i | FoundChr ci c is <- foundChrs, i <- is ]
          
                    -- each found combi has to match
                    foundWorkMatches <- fmap concat $ forM foundWorkInxs $ \(FoundWorkInx ci c wis) -> do
                      forM wis $ \wi -> do
                        w <- forM wi lkupWork
                        fmap (FoundWorkMatch ci c wi) $ slvMatch env c (map workCnstr w)

                    -- which we group by backtrack priority (on numerical value) and then rule priority (directly comparing), highest to lowest with the ones which cannot be compared at the end
                    let foundWorkMatchesFilteredPriod = map assocLElts (groupSortByOn (chrPrioCompare env) fst forCmp) ++ (if List.null noCmp then [] else [noCmp])
                          where (forCmp, noCmp) = partitionOnSplit id fromJust isJust [ (fmap ((,) s) pr,(ci,c,wi,s)) | FoundWorkMatch ci c wi (Just (FoundSlvMatch pr s _ _)) <- foundWorkMatches ]

                    -- debug info
                    sndl ^* chrbstReductionSteps =$: (SolverReductionDBG
                      (    "wk" >#< work
                       >-< "que" >#< ppBracketsCommas (Set.toList activeWk)
                       >-< "visited" >#< ppBracketsCommas (Set.toList visitedChrWkCombis)
                       >-< "chrs" >#< vlist [ ci >|< ppParensCommas is >|< ":" >#< c | FoundChr ci c is <- foundChrs ]
                       >-< "works" >#< vlist [ ci >|< ":" >#< vlist (map ppBracketsCommas ws) | FoundWorkInx ci c ws <- foundWorkInxs ]
                       >-< "matches" >#< vlist [ ci >|< ":" >#< ppBracketsCommas wi >#< ":" >#< mbm | FoundWorkMatch ci _ wi mbm <- foundWorkMatches ]
                       >-< "prio'd" >#< (vlist $ zipWith (\g ms -> g >|< ":" >#< vlist [ ci >|< ":" >#< ppBracketsCommas wi >#< ":" >#< s | (ci,_,wi,s) <- ms ]) [0::Int ..] foundWorkMatchesFilteredPriod)
                      ) :)

                    {-
                    -- actual solving, backtracking etc
                    addWorkToRuleWorkQueue workInx
                    -- for now, leave out the backtracking part
                    slvPrios foundWorkMatchesFilteredPriod
                    -}
                    -- instead, pick one, if any
                    case foundWorkMatchesFilteredPriod of
                      -- at least one solution to follow up
                      ((a:_):_) -> do
                            addWorkToRuleWorkQueue workInx
                            slv1 a
                      _ | chrslvOptSucceedOnLeftoverWork opts -> do
                            -- no chr applies for this work, so consider it to be residual
                            sndl ^* chrbstLeftWorkQueue =$: (workInx :)
                            slv
                        | otherwise -> do
                            -- no chr applies for this work, can never be resolved, consider this a failure unless prevented by option
                            mzero

{-
    -- solve a group of matches with same prio, cutting of alternatives from other lower priorities if this priority has a solution
    slvPrios foundWorkMatchesFilteredPriod = case foundWorkMatchesFilteredPriod of
        (ms:mss) -> ifte (slvMatches ms) return (slvPrios mss)
        _        -> mzero

    -- 
    slvMatches matches = do
      alts <- forM matches $ backtrack . slv1
      msum alts
-}

    -- solve one step further, allowing a backtrack point here
    slv1 (CHRConstraintInx {chrciInx = ci}, StoredCHR {_storedChrRule = rul@(Rule {ruleSimpSz = simpSz})}, workInxs, matchSubst) = do
        let body = ruleBody rul
        -- remove the simplification part from the work queue
        deleteWorkFromQueue $ take simpSz workInxs
        -- add each constraint from the body, applying the meta var subst
        newWkInxs <- forM body $ addConstraintAsWork . (matchSubst `varUpd`)
        -- mark this combi of chr and work as visited
        let matchedCombi = MatchedCombi ci workInxs
        sndl ^* chrbstMatchedCombis =$: Set.insert matchedCombi
        -- add this reduction step as being taken
        sndl ^* chrbstReductionSteps =$: (SolverReductionStep matchedCombi (Map.unionsWith (++) $ map (\(k,v) -> Map.singleton k [v]) $ newWkInxs) :)
        -- result
        -- return emptySolverResult
        slv

    -- misc utils
    
{-
chrSolve
  :: forall env c g b p s .
     ( IsCHRSolvable env c g bp p s
     )
     => env
     -> CHRStore c g b p
     -> [c]
     -> [c]
chrSolve env chrStore cnstrs
  = work ++ done
  where (work, done, _ :: SolveTrace c g b p s) = chrSolve' [] env chrStore cnstrs
-}

{-
-- | Solve
chrSolve'
  :: forall env c g b p s .
     ( IsCHRSolvable env c g bp p s
     )
     => [CHRTrOpt]
     -> env
     -> CHRStore c g b p
     -> [c]
     -> ([c],[c],SolveTrace c g b p s)
chrSolve' tropts env chrStore cnstrs
  = (wlToList (stWorkList finalState), stDoneCnstrs finalState, stTrace finalState)
  where finalState = chrSolve'' tropts env chrStore cnstrs emptySolveState

-- | Solve
chrSolve''
  :: forall env c g b p s .
     ( IsCHRSolvable env c g bp p s
     )
     => [CHRTrOpt]
     -> env
     -> CHRStore c g b p
     -> [c]
     -> SolveState c g b p s
     -> SolveState c g b p s
chrSolve'' tropts env chrStore cnstrs prevState
  = flip execState prevState $ chrSolveM tropts env chrStore cnstrs

-- | Solve
chrSolveM
  :: forall env c g b p s .
     ( IsCHRSolvable env c g bp p s
     )
     => [CHRTrOpt]
     -> env
     -> CHRStore c g b p
     -> [c]
     -> State (SolveState c g b p s) ()
chrSolveM tropts env chrStore cnstrs = do
    modify initState
    iter
{-
    modify $
            addStats Map.empty
                [ ("workMatches",ppAssocLV [(ppTreeTrieKey k,pp (fromJust l))
                | (k,c) <- Map.toList $ stCountCnstr st, let l = Map.lookup "workMatched" c, isJust l])
                ]
-}
    modify $ \st -> st {stMatchCache = Map.empty}
  where iter = do
          st <- get
          case st of
            (SolveState {stWorkList = wl@(WorkList {wlQueue = (workHd@(workHdKey,_) : workTl)})}) ->
                case matches of
                  (_:_) -> do
                      put 
{-   
                          $ addStats Map.empty
                                [ ("(0) yes work", ppTreeTrieKey workHdKey)
                                ]
                          $
-}    
                          stmatch
                      expandMatch matches
                    where -- expandMatch :: SolveState c g b p s -> [((StoredCHR c g bp p, ([WorkKey c], [Work c])), s)] -> SolveState c g b p s
                          expandMatch ( ( ( schr@(StoredCHR {storedIdent = chrId, storedChrRule = chr@(Rule {ruleSimpSz = simpSz})})
                                          , (keys,works)
                                          )
                                        , subst
                                        ) : tlMatch
                                      ) = do
                              let b = ruleBody chr
                              st@(SolveState {stWorkList = wl, stHistoryCount = histCount}) <- get
                              let (tlMatchY,tlMatchN) = partition (\(r@(_,(ks,_)),_) -> not (any (`elem` keysSimp) ks || slvIsUsedByPropPart (wlUsedIn wl') r)) tlMatch
                                  (keysSimp,keysProp) = splitAt simpSz keys
                                  usedIn              = Map.singleton (Set.fromList keysProp) (Set.singleton chrId)
                                  (bTodo,bDone)       = splitDone $ map (varUpd subst) b
                                  bTodo'              = wlCnstrToIns wl bTodo
                                  wl' = wlDeleteByKeyAndInsert' histCount keysSimp bTodo'
                                        $ wl { wlUsedIn  = usedIn `wlUsedInUnion` wlUsedIn wl
                                             , wlScanned = []
                                             , wlQueue   = wlQueue wl ++ wlScanned wl
                                             }
                                  st' = st { stWorkList       = wl'
{-  
                                           , stTrace          = SolveStep chr' subst (assocLElts bTodo') bDone : {- SolveDbg (ppwork >-< ppdbg) : -} stTrace st
-}    
                                           , stDoneCnstrSet   = Set.unions [Set.fromList bDone, Set.fromList $ map workCnstr $ take simpSz works, stDoneCnstrSet st]
                                           , stMatchCache     = if List.null bTodo' then stMatchCache st else Map.empty
                                           , stHistoryCount   = histCount + 1
                                           }
{-   
                                  chr'= subst `varUpd` chr
                                  ppwork = "workkey" >#< ppTreeTrieKey workHdKey >#< ":" >#< (ppBracketsCommas (map (ppTreeTrieKey . fst) workTl) >-< ppBracketsCommas (map (ppTreeTrieKey . fst) $ wlScanned wl))
                                             >-< "workkeys" >#< ppBracketsCommas (map ppTreeTrieKey keys)
                                             >-< "worktrie" >#< wlTrie wl
                                             >-< "schr" >#< schr
                                             >-< "usedin" >#< (ppBracketsCommasBlock $ map (\(k,s) -> ppKs k >#< ppBracketsCommas (map ppUsedByKey $ Set.toList s)) $ Map.toList $ wlUsedIn wl)
                                             >-< "usedin'" >#< (ppBracketsCommasBlock $ map (\(k,s) -> ppKs k >#< ppBracketsCommas (map ppUsedByKey $ Set.toList s)) $ Map.toList $ wlUsedIn wl')
                                         where ppKs ks = ppBracketsCommas $ map ppTreeTrieKey $ Set.toList ks
-}   
                              put
{-   
                                  $ addStats Map.empty
                                        [ ("chr",pp chr')
                                        , ("leftover sz", pp (length tlMatchY))
                                        , ("filtered out sz", pp (length tlMatchN))
                                        , ("new done sz", pp (length bDone))
                                        , ("new todo sz", pp (length bTodo))
                                        , ("wl queue sz", pp (length (wlQueue wl')))
                                        , ("wl usedin sz", pp (Map.size (wlUsedIn wl')))
                                        , ("done sz", pp (Set.size (stDoneCnstrSet st')))
                                        , ("hist cnt", pp histCount)
                                        ]
                                  $
-}   
                                  st'
                              expandMatch tlMatchY

                          expandMatch _ 
                            = iter
                          
                  _ -> do
                      put
{-   
                          $ addStats Map.empty
                                [ ("no match work", ppTreeTrieKey workHdKey)
                                , ("wl queue sz", pp (length (wlQueue wl')))
                                ]
                          $
-}    
                          st'
                      iter
                    where wl' = wl { wlScanned = workHd : wlScanned wl, wlQueue = workTl }
                          st' = stmatch { stWorkList = wl', stTrace = SolveDbg (ppdbg) : {- -} stTrace stmatch }
              where (matches,lastQuery,ppdbg,stats) = workMatches st
{-  
                    stmatch = addStats stats [("(a) workHd", ppTreeTrieKey workHdKey), ("(b) matches", ppBracketsCommasBlock [ s `varUpd` storedChrRule schr | ((schr,_),s) <- matches ])]
-}
                    stmatch =  
                                (st { stCountCnstr = scntInc workHdKey "workMatched" $ stCountCnstr st
                                    , stMatchCache = Map.insert workHdKey [] (stMatchCache st)
                                    , stLastQuery  = lastQuery
                                    })
            _ -> do
                return ()

        mkStats  stats new    = stats `Map.union` Map.fromList (assocLMapKey showPP new)
{-
        addStats stats new st = st { stTrace = SolveStats (mkStats stats new) : stTrace st }
-}
        addStats _     _   st = st

        workMatches st@(SolveState {stWorkList = WorkList {wlQueue = (workHd@(workHdKey,Work {workTime = workHdTm}) : _), wlTrie = wlTrie, wlUsedIn = wlUsedIn}, stHistoryCount = histCount, stLastQuery = lastQuery})
          | isJust mbInCache  = ( fromJust mbInCache
                                , lastQuery
                                , Pretty.empty, mkStats Map.empty [("cache sz",pp (Map.size (stMatchCache st)))]
                                )
          | otherwise         = ( r5
                                , foldr lqUnion lastQuery [ lqSingleton ck wks histCount | (_,(_,(ck,wks))) <- r23 ]
{-
                                -- , Pretty.empty
                                , pp2 >-< {- pp2b >-< pp2c >-< -} pp3
                                , mkStats Map.empty [("(1) lookup sz",pp (length r2)), ("(2) cand sz",pp (length r3)), ("(3) unused cand sz",pp (length r4)), ("(4) final cand sz",pp (length r5))]
-}
                                , Pretty.empty
                                , Map.empty
                                )
          where -- cache result, if present use that, otherwise the below computation
                mbInCache = Map.lookup workHdKey (stMatchCache st)
                
                -- results, stepwise computed for later reference in debugging output
                -- basic search result
                r2 :: [StoredCHR c g bp p]                                       -- CHRs matching workHdKey
                r2  = concat                                                    -- flatten
                        $ TreeTrie.lookupResultToList                                   -- convert to list
                        $ chrTrieLookup chrLookupHowWildAtTrie workHdKey        -- lookup the store, allowing too many results
                        $ chrstoreTrie chrStore
                
                -- lookup further info in wlTrie, in particular to find out what has been done already
                r23 :: [( StoredCHR c g bp p                                     -- the CHR
                        , ( [( [(CHRKey c, Work c)]                             -- for each CHR the list of constraints, all possible work matches
                             , [(CHRKey c, Work c)]
                             )]
                          , (CHRKey c, Set.Set (CHRKey c))
                        ) )]
                r23 = map (\c -> (c, slvCandidate workHdKey lastQuery wlTrie c)) r2
                
                -- possible matches
                r3, r4
                    :: [( StoredCHR c g bp p                                     -- the matched CHR
                        , ( [CHRKey c]                                            -- possible matching constraints (matching with the CHR constraints), as Keys, as Works
                          , [Work c]
                        ) )]
                r3  = concatMap (\(c,cands) -> zip (repeat c) (map unzip $ slvCombine cands)) $ r23
                
                -- same, but now restricted to not used earlier as indicated by the worklist
                r4  = filter (not . slvIsUsedByPropPart wlUsedIn) r3
                
                -- finally, the 'real' match of the 'real' constraint, yielding (by tupling) substitutions instantiating the found trie matches
                r5  :: [( ( StoredCHR c g bp p
                          , ( [CHRKey c]          
                            , [Work c]
                          ) )
                        , s
                        )]
                r5  = mapMaybe (\r@(chr,kw@(_,works)) -> fmap (\s -> (r,s)) $ slvMatch env chr (map workCnstr works)) r4
{-
                -- debug info
                pp2  = "lookups"    >#< ("for" >#< ppTreeTrieKey workHdKey >-< ppBracketsCommasBlock r2)
                -- pp2b = "cand1"      >#< (ppBracketsCommasBlock $ map (ppBracketsCommasBlock . map (ppBracketsCommasBlock . map (\(k,w) -> ppTreeTrieKey k >#< w)) . fst . candidate) r2)
                -- pp2c = "cand2"      >#< (ppBracketsCommasBlock $ map (ppBracketsCommasBlock . map (ppBracketsCommasBlock) . combineToDistinguishedElts . fst . candidate) r2)
                pp3  = "candidates" >#< (ppBracketsCommasBlock $ map (\(chr,(ks,ws)) -> "chr" >#< chr >-< "keys" >#< ppBracketsCommas (map ppTreeTrieKey ks) >-< "works" >#< ppBracketsCommasBlock ws) $ r3)
-}
        initState st = st { stWorkList = wlInsert (stHistoryCount st) wlnew $ stWorkList st, stDoneCnstrSet = Set.unions [Set.fromList done, stDoneCnstrSet st] }
                     where (wlnew,done) = splitDone cnstrs
        splitDone  = partition cnstrRequiresSolve

-}


-- | Extract candidates matching a CHRKey.
--   Return a list of CHR matches,
--     each match expressed as the list of constraints (in the form of Work + Key) found in the workList wlTrie, thus giving all combis with constraints as part of a CHR,
--     partititioned on before or after last query time (to avoid work duplication later)
slvCandidate
  :: ( MonoBacktrackPrio c g bp p s e m
     -- , Ord (TTKey c), PP (TTKey c)
     ) => Set.Set WorkInx                           -- ^ active in queue
       -> Set.Set MatchedCombi                      -- ^ already matched combis
       -> CHRKey c                                  -- ^ work key
       -- -> LastQuery c
       -- -> WorkTrie c
       -> StoredCHR c g bp p                           -- ^ found chr for the work
       -> Int                                       -- ^ position in the head where work was found
       -> CHRMonoBacktrackPrioT c g bp p s e m
            ( [[WorkInx]]                           -- All matches of the head, unfiltered w.r.t. deleted work
            )
       -- -> ( [( [(CHRKey c, Work c)]
       --       , [(CHRKey c, Work c)]
       --       )]
       --    , (CHRKey c, Set.Set (CHRKey c))
       --    )
slvCandidate activeInQueue alreadyMatchedCombis workHdKey {- lastQuery wlTrie -} (StoredCHR {_storedHeadKeys = ks, _storedChrInx = ci}) headInx = do
    let [ks1,_,ks2] = splitPlaces [headInx, headInx+1] ks
    ws1 <- forM ks1 $ lkup TTL_WildInKey
    w   <-            lkup TTL_Exact     workHdKey
    ws2 <- forM ks2 $ lkup TTL_WildInKey
    return $ filter (\wi ->    all (`Set.member` activeInQueue) wi
                            && Set.notMember (MatchedCombi ci wi) alreadyMatchedCombis)
           $ combineToDistinguishedEltsBy (==) $ ws1 ++ [w] ++ ws2
  where
    lkup how k = do
      fmap (concat . TreeTrie.lookupResultToList . TreeTrie.lookupPartialByKey how k) $ getl $ fstl ^* chrgstWorkStore ^* wkstoreTrie
{-
  = ( map (maybe (lkup TTL_Exact workHdKey) (lkup TTL_WildInKey)) ks
    , ( ck
      , Set.fromList $ map (maybe workHdKey id) ks
    ) )
  where lkup how k = partition (\(_,w) -> workTime w < lastQueryTm) $ map (\w -> (workKey w,w)) $ TreeTrie.lookupResultToList $ TreeTrie.lookupPartialByKey how k wlTrie
                   where lastQueryTm = lqLookupW k $ lqLookupC ck lastQuery
{-# INLINE slvCandidate #-}
-}

{-

-- | Extract candidates matching a CHRKey.
--   Return a list of CHR matches,
--     each match expressed as the list of constraints (in the form of Work + Key) found in the workList wlTrie, thus giving all combis with constraints as part of a CHR,
--     partititioned on before or after last query time (to avoid work duplication later)
slvCandidate
  :: (Ord (TTKey c), PP (TTKey c))
     => CHRKey c
     -> LastQuery c
     -> WorkTrie c
     -> StoredCHR c g bp p
     -> ( [( [(CHRKey c, Work c)]
           , [(CHRKey c, Work c)]
           )]
        , (CHRKey c, Set.Set (CHRKey c))
        )
slvCandidate workHdKey lastQuery wlTrie (StoredCHR {storedIdent = (ck,_), storedKeys = ks, storedChrRule = chr})
  = ( map (maybe (lkup chrLookupHowExact workHdKey) (lkup chrLookupHowWildAtKey)) ks
    , ( ck
      , Set.fromList $ map (maybe workHdKey id) ks
    ) )
  where lkup how k = partition (\(_,w) -> workTime w < lastQueryTm) $ map (\w -> (workKey w,w)) $ TreeTrie.lookupResultToList $ chrTrieLookup how k wlTrie
                   where lastQueryTm = lqLookupW k $ lqLookupC ck lastQuery
{-# INLINE slvCandidate #-}

-- | Check whether the CHR propagation part of a match already has been used (i.e. propagated) earlier,
--   this to avoid duplicate propagation.
slvIsUsedByPropPart
  :: (Ord k, Ord (TTKey c))
     => Map.Map (Set.Set k) (Set.Set (UsedByKey c))
     -> (StoredCHR c g bp p, ([k], t))
     -> Bool
slvIsUsedByPropPart wlUsedIn (chr,(keys,_))
  = fnd $ drop (storedSimpSz chr) keys
  where fnd k = maybe False (storedIdent chr `Set.member`) $ Map.lookup (Set.fromList k) wlUsedIn
{-# INLINE slvIsUsedByPropPart #-}

-}

-- | Match the stored CHR with a set of possible constraints, giving a substitution on success
slvMatch
  :: ( {-
       CHREmptySubstitution s
     , VarLookupCmb s s
     , -}
       MonoBacktrackPrio c g bp p s e m
     {- these below should not be necessary as they are implied (via superclasses) by MonoBacktrackPrio, but deeper nested superclasses seem not to be picked up...
     -}
     , CHRMatchable env c s
     , CHRCheckable env g s
     , CHRMatchable env bp s
     -- , CHRPrioEvaluatable env p s
     , CHRPrioEvaluatable env bp s
     -- , CHRBuiltinSolvable env b s
     -- , PP s
     )
     => env
     -> StoredCHR c g bp p
     -> [c]
     -> CHRMonoBacktrackPrioT c g bp p s e m (Maybe (FoundSlvMatch c g bp p s))
slvMatch env chr@(StoredCHR {_storedChrRule = Rule {rulePrio = mbpr, ruleHead = hc, ruleGuard = gd, ruleBacktrackPrio = mbbpr, ruleBodyAlts = alts}}) cnstrs = do
    subst <- getl $ sndl ^* chrbstSolveSubst
    curbprio <- getl $ sndl ^* chrbstBacktrackPrio
    return $ fmap (\(s,ws) -> FoundSlvMatch mbpr s ws [(maybe minBound (chrPrioEval env s) $ rbodyaltBacktrackPrio a, a) | a <- alts])
           $ flip chrmatcherRun subst
           $ sequence_
           $ prio curbprio ++ matches ++ checks
  where
    prio curbprio = maybe [] (\bpr -> [chrMatchToM env bpr curbprio]) mbbpr
    matches = zipWith (chrMatchToM env) hc cnstrs
    checks  = map (chrCheckM env) gd
{-
slvMatch env chr@(StoredCHR {_storedChrRule = Rule {rulePrio = mbpr}}) cnstrs = return $ do
    subst <- foldl cmb (Just chrEmptySubst) $ matches chr cnstrs ++ checks chr
    return ({- maybe minBound (chrPrioEval env subst) -} mbpr, subst)
  where
    matches (StoredCHR {_storedChrRule = Rule {ruleHead = hc}}) cnstrs
      = zipWith mt hc cnstrs
      where mt cFr cTo subst = chrMatchTo env subst cFr cTo
    checks (StoredCHR {_storedChrRule = Rule {ruleGuard = gd}})
      = map chk gd
      where chk g subst = chrCheck env subst g
    cmb (Just s) next = fmap (|+> s) $ next s
    cmb _        _    = Nothing
-}
{-
slvMatch env chr@(StoredCHR {_storedChrRule = Rule {rulePrio = mbpr}}) cnstrs = do
    return $ flip runStateT chrEmptySubst $ do
      sequence_ (matches chr cnstrs ++ checks chr)
      subst <- get
      -- liftIO (putPPLn (pp subst))
      return $ maybe maxBound (chrPrioEval env subst) mbpr
  where
    wrap f = get >>= \subst -> lift (f subst) >>= \s -> return (trp "slvMatch.lift.f" s s) >>= \s -> return (trp "slvMatch.s" s s |+> trp "slvMatch.subst" subst subst)
    matches (StoredCHR {_storedChrRule = Rule {ruleHead = hc}}) cnstrs
      = zipWith (\cFr cTo -> wrap $ \subst -> let ms = chrMatchTo env subst cFr cTo in trp "slvMatch.chrMatchTo" ms ms) hc cnstrs
    checks (StoredCHR {_storedChrRule = Rule {ruleGuard = gd}})
      = map (\g -> wrap $ \subst -> chrCheck env subst g) gd
-}

{-
slvMatch
  :: ( CHREmptySubstitution s
     , CHRMatchable env c s
     , CHRCheckable env g s
     , VarLookupCmb s s
     )
     => env -> StoredCHR c g bp p -> [c] -> Maybe s
slvMatch env chr cnstrs
  = foldl cmb (Just chrEmptySubst) $ matches chr cnstrs ++ checks chr
  where matches (StoredCHR {storedChrRule = Rule {ruleHead = hc}}) cnstrs
          = zipWith mt hc cnstrs
          where mt cFr cTo subst = chrMatchTo env subst cFr cTo
        checks (StoredCHR {storedChrRule = Rule {ruleGuard = gd}})
          = map chk gd
          where chk g subst = chrCheck env subst g
        cmb (Just s) next = fmap (|+> s) $ next s
        cmb _        _    = Nothing
{-# INLINE slvMatch #-}

-}

-------------------------------------------------------------------------------------------
--- Instances: Serialize
-------------------------------------------------------------------------------------------

{-
instance (Ord (TTKey c), Serialize (TTKey c), Serialize c, Serialize g, Serialize b, Serialize p) => Serialize (CHRStore c g b p) where
  sput (CHRStore a) = sput a
  sget = liftM CHRStore sget
  
instance (Serialize c, Serialize g, Serialize b, Serialize p, Serialize (TTKey c)) => Serialize (StoredCHR c g bp p) where
  sput (StoredCHR a b c d) = sput a >> sput b >> sput c >> sput d
  sget = liftM4 StoredCHR sget sget sget sget

-}
