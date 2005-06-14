-----------------------------------------------------------------------------
-- |
-- Module      :  Network.CGI
-- Copyright   :  (c) The University of Glasgow 2001
--                (c) Bjorn Bringert 2004
-- License     :  BSD-style (see the file libraries/network/LICENSE)
-- 
-- Maintainer  :  bjorn@bringert.net
-- Stability   :  experimental
-- Portability :  non-portable (uses Control.Monad.State)
--
-- Simple library for writing CGI programs.
--
-- Based on the original Haskell binding for CGI:
--
-- Original Version by Erik Meijer <mailto:erik@cs.ruu.nl>.
-- Further hacked on by Sven Panne <mailto:sven.panne@aedion.de>.
-- Further hacking by Andy Gill <mailto:andy@galconn.com>.
--
-----------------------------------------------------------------------------

module Network.NewCGI (
  -- * The CGI monad
    CGI, CGIResult
  , io, runCGI, hRunCGI
  -- * Output
  , output, redirect
  , setHeader
  -- * Input
  , getInput, readInput, getInputs
  , getVar, getVars
  -- * Cookies
  , Cookie(..), newCookie
  , getCookie, setCookie, deleteCookie
  -- * Compatibility
  , Html, wrapper, pwrapper, connectToCGIScript
  ) where

import Control.Monad.State
import Data.Maybe (listToMaybe)
import Network.HTTP.Cookie (Cookie(..), newCookie, findCookie)
import qualified Network.HTTP.Cookie as Cookie (setCookie, deleteCookie)
import Network.URI (unEscapeString)
import System.Environment (getEnv)
import System.IO (Handle, hPutStr, hPutStrLn, hGetContents, stdin, stdout)

-- imports only needed by the compatibility functions
import Control.Concurrent (forkIO)
import Control.Exception as Exception (Exception,throw,catch,finally)
import Network (PortID, Socket, listenOn, connectTo)
import Network.Socket as Socket (SockAddr(SockAddrInet), accept, socketToHandle)
import System.IO (hGetLine, hClose, IOMode(ReadWriteMode))
import System.IO.Error (catch, isEOFError)
import Text.Html (Html, renderHtml)


data CGIState = CGIState {
			  cgiVars :: [(String,String)],
			  cgiInput :: [(String,String)],
			  cgiResponseHeaders :: [(String,String)]
			 }
	      deriving (Show, Read, Eq, Ord)

-- | The CGI monad. FIXME: maybe this should be abstract?
type CGI a = StateT CGIState IO a 

-- | The result of a CGI program.
data CGIResult = CGIOutput String
	       | CGIRedirect String
		 deriving (Show, Read, Eq, Ord)

--
-- * CGI monad
--

-- | Perform an IO action in the CGI monad
io :: IO a -> CGI a
io = lift

-- | Run a CGI action. Typically called by the main function.
--   Reads input from stdin and writes to stdout.
--   Note: if using Windows, you might need to wrap 'withSocketsDo' round main.
runCGI :: CGI CGIResult -> IO ()
runCGI = hRunCGI stdin stdout

-- | Run a CGI action. Typically called by the main function.
--   Note: if using Windows, you might need to wrap 'withSocketsDo' round main.
hRunCGI :: Handle -- ^ Handle that input will be read from.
	-> Handle -- ^ Handle that output will be written to.
	-> CGI CGIResult -> IO ()
hRunCGI hin hout f 
    = do qs <- getQueryString hin
	 vars <- getCgiVars
	 let s = CGIState{
			  cgiVars = vars,
			  cgiInput = formDecode qs,
			  cgiResponseHeaders = initHeaders
			 }
	 (output,s') <- runStateT f s
	 let hs = cgiResponseHeaders s'
	 case output of
		     CGIOutput str   -> doOutput hout str hs
		     CGIRedirect url -> doRedirect hout url hs


doOutput :: Handle -> String -> [(String,String)] -> IO ()
doOutput h str hs = 
    do
    let hs' = tableAddIfNotPresent "Content-type" "text/html; charset=ISO-8859-1" hs
    printHeaders h hs'
    hPutStrLn h ""
    hPutStr h str

doRedirect :: Handle -> String -> [(String,String)] -> IO ()
doRedirect h url hs =
    do
    let hs' = tableSet "Location" url hs
    printHeaders h hs'
    hPutStrLn h ""

--
-- * Output \/ redirect
--

-- | Output a string. The output is assumed to be text\/html, encoded using
--   ISO-8859-1. To change this, set the Content-type header using
--   'setHeader'.
output :: String        -- ^ The string to output.
       -> CGI CGIResult
output str = return $ CGIOutput str

-- | Redirect to some location.
redirect :: String        -- ^ A URL to redirect to.
	 -> CGI CGIResult
redirect str = return $ CGIRedirect str

--
-- * HTTP variables
--

-- | Get the value of a CGI environment variable. Example:
--
-- > remoteAddr <- getVar "REMOTE_ADDR"
getVar :: String             -- ^ The name of the variable.
       -> CGI (Maybe String)
getVar name = gets (lookup name . cgiVars)

-- | Get all CGI environment variables and their values.
getVars :: CGI [(String,String)]
getVars = gets cgiVars

--
-- * Query input
--

-- | Get an input variable, for example from a form.
--   Example:
--
-- > query <- getInput "query"
getInput :: String             -- ^ The name of the variable.
	 -> CGI (Maybe String) -- ^ The value of the variable,
                               --   or Nothing, if it was not set.
getInput name = gets (lookup name . cgiInput)

-- | Same as 'getInput', but tries to read the value to the desired type.
readInput :: Read a => 
	     String        -- ^ The name of the variable.
	  -> CGI (Maybe a) -- ^ 'Nothing' if the variable does not exist
	                   --   or if the value could not be interpreted
	                   --   as the desired type.
readInput name = liftM (>>= fmap fst . listToMaybe . reads) (getInput name)

-- | Get all input variables and their values.
getInputs :: CGI [(String,String)]
getInputs = gets cgiInput

--
-- * Cookies
--

-- | Get the value of a cookie.
getCookie :: String             -- ^ The name of the cookie.
	  -> CGI (Maybe String)
getCookie name = do
		 cs <- getVar "HTTP_COOKIE"
		 return $ maybe Nothing (findCookie name) cs

-- | Set a cookie.
setCookie :: Cookie -> CGI ()
setCookie cookie = 
    modify (\s -> s{cgiResponseHeaders 
		    = Cookie.setCookie cookie (cgiResponseHeaders s)})

-- | Delete a cookie from the client
deleteCookie :: Cookie -> CGI ()
deleteCookie cookie = setCookie (Cookie.deleteCookie cookie)


--
-- * Headers
--

-- | Set a response header.
--   Example:
--
-- > setHeader "Content-type" "text/plain"
setHeader :: String -- ^ Header name.
	  -> String -- ^ Header value.
	  -> CGI ()
setHeader name value = 
    modify (\s -> s{cgiResponseHeaders 
		    = tableSet name value (cgiResponseHeaders s)})

showHeader :: (String,String) -> String
showHeader (n,v) = n ++ ": " ++ v

printHeaders :: Handle ->[(String,String)] -> IO ()
printHeaders h = mapM_ (hPutStrLn h . showHeader)

initHeaders :: [(String,String)]
initHeaders = []

--
-- * Utilities
--

-- | Get the name-value pairs from application\/x-www-form-urlencoded data.
formDecode :: String -> [(String,String)]
formDecode "" = []
formDecode s = (urlDecode n, urlDecode (drop 1 v)) : formDecode (drop 1 rs)
    where (nv,rs) = break (=='&') s
	  (n,v) = break (=='=') nv

-- | Convert a single value from the application\/x-www-form-urlencoded encoding.
urlDecode :: String -> String
urlDecode = unEscapeString . replace '+' ' '

-- | Replace all instances of a value in a list by another value.
replace :: Eq a => 
	   a   -- ^ Value to look for
	-> a   -- ^ Value to replace it with
	-> [a] -- ^ Input list
	-> [a] -- ^ Output list
replace x y = map (\z -> if z == x then y else z)

-- | Set a value in a lookup table.
tableSet :: Eq a => a -> b -> [(a,b)] -> [(a,b)]
tableSet k v [] = [(k,v)]
tableSet k v ((k',v'):ts) 
    | k == k' = (k,v) : ts
    | otherwise = (k',v') : tableSet k v ts

-- | Add a key, value pair to a table only if there is no entry
--   with the given key already in the table. If there is an entry
--   already, nothing is done.
tableAddIfNotPresent :: Eq a => a -> b -> [(a,b)] -> [(a,b)]
tableAddIfNotPresent k v [] = [(k,v)]
tableAddIfNotPresent k v ((k',v'):ts) 
    | k == k' = (k',v') : ts
    | otherwise = (k',v') : tableAddIfNotPresent k v ts

--
-- * CGI protocol stuff
--

getCgiVars :: IO [(String,String)]
getCgiVars = do vals <- mapM myGetEnv cgiVarNames
                return (zip cgiVarNames vals)

cgiVarNames :: [String]
cgiVarNames =
   [ "DOCUMENT_ROOT"
   , "AUTH_TYPE"
   , "GATEWAY_INTERFACE"
   , "SERVER_SOFTWARE"
   , "SERVER_NAME"
   , "REQUEST_METHOD"
   , "SERVER_ADMIN"
   , "SERVER_PORT"
   , "QUERY_STRING"
   , "CONTENT_LENGTH"
   , "CONTENT_TYPE"
   , "REMOTE_USER"
   , "REMOTE_IDENT"
   , "REMOTE_ADDR"
   , "REMOTE_HOST"
   , "TZ"
   , "PATH"
   , "PATH_INFO"
   , "PATH_TRANSLATED"
   , "SCRIPT_NAME"
   , "SCRIPT_FILENAME"
   , "HTTP_COOKIE"
   , "HTTP_CONNECTION"
   , "HTTP_ACCEPT_LANGUAGE"
   , "HTTP_ACCEPT"
   , "HTTP_HOST"
   , "HTTP_UA_COLOR"
   , "HTTP_UA_CPU"
   , "HTTP_UA_OS"
   , "HTTP_UA_PIXELS"
   , "HTTP_USER_AGENT"
   ]                      

getQueryString :: Handle -> IO String
getQueryString h = do
   method <- myGetEnv "REQUEST_METHOD"
   case method of
      "POST" -> do len <- myGetEnv "CONTENT_LENGTH"
                   inp <- hGetContents h
                   return (take (read len) inp)
      _      -> myGetEnv "QUERY_STRING"

myGetEnv :: String -> IO String
myGetEnv v = Prelude.catch (getEnv v) (const (return ""))

--
-- * Compatibility functions
--

{-# DEPRECATED wrapper, pwrapper, connectToCGIScript "Use the new interface." #-}

-- | Compatibility wrapper for the old CGI interface. 
--   Output the output from a function from CGI environment and 
--   input variables to an HTML document.
wrapper :: ([(String,String)] -> IO Html) -> IO ()
wrapper f = runCGI (wrapCGI f)

-- | Compatibility wrapper for the old CGI interface.
--   Runs a simple CGI server.
pwrapper :: PortID  -- ^ The port to run the server on.
	 -> ([(String,String)] -> IO Html) 
	 -> IO ()
pwrapper pid f = do sock <- listenOn pid
		    acceptConnections fn sock
 where fn h = hRunCGI h h (wrapCGI f)

acceptConnections fn sock = do
  (h, SockAddrInet port haddr) <- accept' sock
  forkIO (fn h `finally` (hClose h))
  acceptConnections fn sock

accept' :: Socket 		-- Listening Socket
       -> IO (Handle,SockAddr)	-- StdIO Handle for read/write
accept' sock = do
 (sock', addr) <- Socket.accept sock
 handle	<- socketToHandle sock' ReadWriteMode
 return (handle,addr)

wrapCGI :: ([(String,String)] -> IO Html) -> CGI CGIResult
wrapCGI f = do
	    vs <- getVars
	    is <- getInputs
	    html <- io (f (vs++is))
	    output (renderHtml html)


connectToCGIScript :: String -> PortID -> IO ()
connectToCGIScript host portId
     = do str <- getQueryString stdin
          h <- connectTo host portId
                 `Exception.catch`
                   (\ e -> abort "Cannot connect to CGI daemon." e)
	  hPutStrLn h str
	  (sendBack h `finally` hClose h)
               `Prelude.catch` (\e -> unless (isEOFError e) (ioError e))

abort :: String -> Exception -> IO a
abort msg e = 
    do putStrLn ("Content-type: text/html\n\n" ++
		   "<html><body>" ++ msg ++ "</body></html>")
       throw e

sendBack h = do s <- hGetLine h
                putStrLn s
		sendBack h
