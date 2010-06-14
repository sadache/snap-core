module Snap.Internal.Routing where


------------------------------------------------------------------------------
import           Control.Applicative ((<|>))
import           Data.ByteString (ByteString)
import           Data.ByteString.Internal (c2w)
import qualified Data.ByteString as B
import           Data.Monoid
import qualified Data.Map as Map

------------------------------------------------------------------------------
import           Snap.Internal.Http.Types
import           Snap.Internal.Types


------------------------------------------------------------------------------
{-|

The internal data type you use to build a routing tree.  Matching is
done unambiguously.

'Capture' and 'Dir' routes can have a "fallback" route:

  - For 'Capture', the fallback is routed when there is nothing to capture
  - For 'Dir', the fallback is routed when we can't find a route in its map

Fallback routes are stacked: i.e. for a route like:

> Dir [("foo", Capture "bar" (Action bar) NoRoute)] baz

visiting the URI foo/ will result in the "bar" capture being empty and
triggering its fallback. It's NoRoute, so we go to the nearest parent
fallback and try that, which is the baz action.

-}
data Route a = Action (Snap a)                        -- wraps a 'Snap' action
             | Capture ByteString (Route a) (Route a) -- captures the dir in a param
             | Dir (Map.Map ByteString (Route a)) (Route a)  -- match on a dir
             | NoRoute


------------------------------------------------------------------------------
instance Monoid (Route a) where
    mempty = NoRoute

    mappend NoRoute r = r

    mappend l@(Action a) r = case r of
      (Action a')       -> Action (a <|> a')
      (Capture p r' fb) -> Capture p r' (mappend fb l)
      (Dir _ _)         -> mappend (Dir Map.empty l) r
      NoRoute           -> l

    -- Whenever we're unioning two Captures and their capture variables
    -- differ, we have an ambiguity. We resolve this in the following order:
    --   1. Prefer whichever route is longer
    --   2. Else, prefer whichever has the earliest non-capture
    --   3. Else, prefer the right-hand side
    mappend l@(Capture p r' fb) r = case r of
      (Action _)           -> Capture p r' (mappend fb r)
      (Capture p' r'' fb')
              | p == p'    -> Capture p (mappend r' r'') (mappend fb fb')
              | rh' > rh'' -> Capture p r' (mappend fb r)
              | rh' < rh'' -> Capture p' r'' (mappend fb' l)
              | en' < en'' -> Capture p r' (mappend fb r)
              | otherwise  -> Capture p' r'' (mappend fb' l)
        where
          rh'  = routeHeight r'
          rh'' = routeHeight r''
          en'  = routeEarliestNC r' 1
          en'' = routeEarliestNC r'' 1
      (Dir rm fb')         -> Dir rm (mappend fb' l)
      NoRoute              -> l

    mappend l@(Dir rm fb) r = case r of
      (Action _)      -> Dir rm (mappend fb r)
      (Capture _ _ _) -> Dir rm (mappend fb r)
      (Dir rm' fb')   -> Dir (Map.unionWith mappend rm rm') (mappend fb fb')
      NoRoute         -> l


------------------------------------------------------------------------------
routeHeight :: Route a -> Int
routeHeight r = case r of
  NoRoute          -> 1
  (Action _)       -> 1
  (Capture _ r' _) -> 1+routeHeight r'
  (Dir rm _)       -> 1+foldl max 1 (map routeHeight $ Map.elems rm)

routeEarliestNC :: Route a -> Int -> Int
routeEarliestNC r n = case r of
  NoRoute           -> n
  (Action _)        -> n
  (Capture _ r' _)  -> routeEarliestNC r' n+1
  (Dir _ _)         -> n


------------------------------------------------------------------------------
-- | A web handler which, given a mapping from URL entry points to web
-- handlers, efficiently routes requests to the correct handler.
--
-- The URL entry points are given as relative paths, for example:
--
-- > route [ ("foo/bar/quux", fooBarQuux) ]
--
-- If the URI of the incoming request is
--
-- > /foo/bar/quux
--
-- or
--
-- > /foo/bar/quux/...anything...
--
-- then the request will be routed to \"@fooBarQuux@\", with 'rqContextPath'
-- set to \"@\/foo\/bar\/quux\/@\" and 'rqPathInfo' set to
-- \"@...anything...@\".
--
-- A path component within an URL entry point beginning with a colon (\"@:@\")
-- is treated as a /variable capture/; the corresponding path component within
-- the request URI will be entered into the 'rqParams' parameters mapping with
-- the given name. For instance, if the routes were:
--
-- > route [ ("foo/:bar/baz", fooBazHandler) ]
--
-- Then a request for \"@\/foo\/saskatchewan\/baz@\" would be routed to
-- @fooBazHandler@ with a mapping for:
--
-- > "bar" => "saskatchewan"
--
-- in its parameters table.
--
-- Longer paths are matched first, and specific routes are matched before
-- captures. That is, if given routes:
--
-- > [ ("a", h1), ("a/b", h2), ("a/:x", h3) ]
--
-- a request for \"@\/a\/b@\" will go to @h2@, \"@\/a\/s@\" for any /s/ will go
-- to @h3@, and \"@\/a@\" will go to @h1@.
--
-- The following example matches \"@\/article@\" to an article index,
-- \"@\/login@\" to a login, and \"@\/article\/...@\" to an article renderer.
--
-- > route [ ("article",     renderIndex)
-- >       , ("article/:id", renderArticle)
-- >       , ("login",       method POST doLogin) ]
--
route :: [(ByteString, Snap a)] -> Snap a
route rts = do
  p <- getProcessingState >>= return . rqPathInfo
  route' (return ()) ([], splitPath p) Map.empty rts'
  where
    rts' = mconcat (map pRoute rts)


------------------------------------------------------------------------------
-- | The 'routeLocal' function is the same as 'route'', except it doesn't change
-- the request's context path. This is useful if you want to route to a
-- particular handler but you want that handler to receive the 'rqPathInfo' as
-- it is.
routeLocal :: [(ByteString, Snap a)] -> Snap a
routeLocal rts = do
    pstate    <- getProcessingState
    let ctx = rqContextPath pstate
    let p   = rqPathInfo pstate
    let md  = modifyProcessingState $ \ps -> ps {rqContextPath=ctx, rqPathInfo=p}

    (route' md ([], splitPath p) Map.empty rts') <|> (md >> pass)

  where
    rts' = mconcat (map pRoute rts)

------------------------------------------------------------------------------
splitPath :: ByteString -> [ByteString]
splitPath = B.splitWith (== (c2w '/'))


------------------------------------------------------------------------------
pRoute :: (ByteString, Snap a) -> Route a
pRoute (r, a) = foldr f (Action a) hier
  where
    hier   = filter (not . B.null) $ B.splitWith (== (c2w '/')) r
    f s rt = if B.head s == c2w ':'
        then Capture (B.tail s) rt NoRoute
        else Dir (Map.fromList [(s, rt)]) NoRoute


------------------------------------------------------------------------------
route' :: Snap ()
       -> ([ByteString], [ByteString])
       -> Params
       -> Route a
       -> Snap a
route' pre (ctx, _) params (Action action) =
    localProcessing (updateContextPath (B.length ctx') . updateParams)
                 (pre >> action)
  where
    ctx' = B.intercalate (B.pack [c2w '/']) (reverse ctx)
    updateParams req = req
      { rqParams = Map.unionWith (++) params (rqParams req) }

route' pre (ctx, [])       params (Capture _ _  fb) =
    route' pre (ctx, []) params fb
route' pre (ctx, cwd:rest) params (Capture p rt fb) =
    (route' pre (cwd:ctx, rest) params' rt) <|>
    (route' pre (ctx, cwd:rest) params  fb)
  where
    params' = Map.insertWith (++) p [cwd] params

route' pre (ctx, [])       params (Dir _   fb) =
    route' pre (ctx, []) params fb
route' pre (ctx, cwd:rest) params (Dir rtm fb) =
    case Map.lookup cwd rtm of
      Just rt -> (route' pre (cwd:ctx, rest) params rt) <|>
                 (route' pre (ctx, cwd:rest) params fb)
      Nothing -> route' pre (ctx, cwd:rest) params fb

route' _ _ _ NoRoute = pass
