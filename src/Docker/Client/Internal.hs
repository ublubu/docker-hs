{-# LANGUAGE OverloadedStrings#-}

module Docker.Client.Internal where

import           Blaze.ByteString.Builder (toByteString)
import qualified Data.Aeson               as JSON
import           Data.Aeson               (ToJSON)
import           Data.ByteString          (ByteString)
import           Data.ByteString.Lazy     (toStrict)
import qualified Data.ByteString.Base64   as Base64
import qualified Data.ByteString.Char8    as BSC
import qualified Data.Conduit.Binary      as CB
import           Data.Text                as T
import           Data.Text.Encoding       (decodeUtf8, encodeUtf8)
import qualified Network.HTTP.Client      as HTTP
import           Network.HTTP.Conduit     (requestBodySourceChunked)
import           Network.HTTP.Types       (Header, Query, encodePath,
                                           encodePathSegments)

import           Docker.Client.Types


encodeURL :: [T.Text] -> T.Text
encodeURL ps = decodeUtf8 $ toByteString $ encodePathSegments ps

encodeURLWithQuery :: [T.Text] -> Query -> T.Text
encodeURLWithQuery ps q = decodeUtf8 $ toByteString $ encodePath ps q

encodeQ :: String -> ByteString
encodeQ = encodeUtf8 . T.pack

getEndpoint :: ApiVersion -> Endpoint -> T.Text
getEndpoint v VersionEndpoint = encodeURL [v, "version"]
getEndpoint v (ListContainersEndpoint _) = encodeURL [v, "containers", "json"] -- Make use of lsOpts here
getEndpoint v (ListImagesEndpoint _) = encodeURL [v, "images", "json"] -- Make use of lsOpts here
getEndpoint v (CreateContainerEndpoint _ cn) = case cn of
        Just cn -> encodeURLWithQuery [v, "containers", "create"] [("name", Just (encodeQ $ T.unpack cn))]
        Nothing -> encodeURL [v, "containers", "create"]
getEndpoint v (StartContainerEndpoint startOpts cid) = encodeURLWithQuery [v, "containers", fromContainerID cid, "start"] query
        where query = case (detachKeys startOpts) of
                WithCtrl c -> [("detachKeys", Just (encodeQ $ ctrl ++ [c]))]
                WithoutCtrl c -> [("detachKeys", Just (encodeQ [c]))]
                DefaultDetachKey -> []
              ctrl = ['c', 't', 'r', 'l', '-']
getEndpoint v (StopContainerEndpoint t cid) = encodeURLWithQuery [v, "containers", fromContainerID cid, "stop"] query
        where query = case t of
                Timeout x      -> [("t", Just (encodeQ $ show x))]
                DefaultTimeout -> []
getEndpoint v (WaitContainerEndpoint cid) = encodeURL [v, "containers", fromContainerID cid, "wait"]
getEndpoint v (KillContainerEndpoint s cid) = encodeURLWithQuery [v, "containers", fromContainerID cid, "kill"] query
        where query = case s of
                SIG x -> [("signal", Just (encodeQ $ show x))]
                _     -> [("signal", Just (encodeQ $ show s))]
getEndpoint v (RestartContainerEndpoint t cid) = encodeURLWithQuery [v, "containers", fromContainerID cid, "restart"] query
        where query = case t of
                Timeout x      -> [("t", Just (encodeQ $ show x))]
                DefaultTimeout -> []
getEndpoint v (PauseContainerEndpoint cid) = encodeURL [v, "containers", fromContainerID cid, "pause"]
getEndpoint v (UnpauseContainerEndpoint cid) = encodeURL [v, "containers", fromContainerID cid, "unpause"]
-- Make use of since/timestamps/tail logopts here instead of ignoreing them
getEndpoint v (ContainerLogsEndpoint (LogOpts stdout stderr _ _ _) follow cid) =
            encodeURLWithQuery    [v, "containers", fromContainerID cid, "logs"] query
        where query = [("stdout", Just (encodeQ $ show stdout)), ("stderr", Just (encodeQ $ show stderr)), ("follow", Just (encodeQ $ show follow))]
getEndpoint v (DeleteContainerEndpoint (DeleteOpts removeVolumes force) cid) =
            encodeURLWithQuery [v, "containers", fromContainerID cid] query
        where query = [("v", Just (encodeQ $ show removeVolumes)), ("force", Just (encodeQ $ show force))]
getEndpoint v (InspectContainerEndpoint cid) =
            encodeURLWithQuery [v, "containers", fromContainerID cid, "json"] []
getEndpoint v (BuildImageEndpoint o _) = encodeURLWithQuery [v, "build"] query
        where query = [("t", Just t), ("dockerfile", Just dockerfile), ("q", Just q), ("nocache", Just nocache), ("rm", Just rm), ("forcerm", Just forcerm), ("pull", Just pull)]
              t = encodeQ $ T.unpack $ buildImageName o
              dockerfile = encodeQ $ T.unpack $ buildDockerfileName o
              q = encodeQ $ show $ buildQuiet o
              nocache = encodeQ $ show $ buildNoCache o
              rm = encodeQ $ show $ buildRemoveItermediate o
              forcerm = encodeQ $ show $ buildForceRemoveIntermediate o
              pull = encodeQ $ show $ buildPullParent o
getEndpoint v (CreateImageEndpoint name tag _) = encodeURLWithQuery [v, "images", "create"] query
        where query = [("fromImage", Just n), ("tag", Just t)]
              n = encodeQ $ T.unpack name
              t = encodeQ $ T.unpack tag
getEndpoint v (PullImageEndpoint _ name tag) = getEndpoint v $ CreateImageEndpoint name tag Nothing
getEndpoint v (PushImageEndpoint _ name tag) = encodeURLWithQuery [v, "images", name, "push"] query
        where query = [("tag", t)]
              t = encodeQ . T.unpack <$> tag

getEndpointRequestBody :: Endpoint -> Maybe HTTP.RequestBody
getEndpointRequestBody VersionEndpoint = Nothing
getEndpointRequestBody (ListContainersEndpoint _) = Nothing
getEndpointRequestBody (ListImagesEndpoint _) = Nothing
getEndpointRequestBody (CreateContainerEndpoint opts _) = Just $ HTTP.RequestBodyLBS (JSON.encode opts)
getEndpointRequestBody (StartContainerEndpoint _ _) = Nothing
getEndpointRequestBody (StopContainerEndpoint _ _) = Nothing
getEndpointRequestBody (WaitContainerEndpoint _) = Nothing
getEndpointRequestBody (KillContainerEndpoint _ _) = Nothing
getEndpointRequestBody (RestartContainerEndpoint _ _) = Nothing
getEndpointRequestBody (PauseContainerEndpoint _) = Nothing
getEndpointRequestBody (UnpauseContainerEndpoint _) = Nothing
getEndpointRequestBody (ContainerLogsEndpoint _ _ _) = Nothing
getEndpointRequestBody (DeleteContainerEndpoint _ _) = Nothing
getEndpointRequestBody (InspectContainerEndpoint _) = Nothing

getEndpointRequestBody (BuildImageEndpoint _ fp) = Just $ requestBodySourceChunked $ CB.sourceFile fp
getEndpointRequestBody (CreateImageEndpoint _ _ _) = Nothing
getEndpointRequestBody (PullImageEndpoint _ _ _) = Nothing
getEndpointRequestBody (PushImageEndpoint _ _ _) = Nothing

getEndpointContentType :: Endpoint -> BSC.ByteString
getEndpointContentType (BuildImageEndpoint _ _) = BSC.pack "application/tar"
getEndpointContentType _ = BSC.pack "application/json; charset=utf-8"

getEndpointHeaders :: Endpoint -> [Header]
getEndpointHeaders (PushImageEndpoint auth _ _) =
  pure ("X-Registry-Auth", toBase64JSON auth)
getEndpointHeaders (PullImageEndpoint auth _ _) =
  pure ("X-Registry-Auth", toBase64JSON auth)
getEndpointHeaders _ = []

toBase64JSON :: (ToJSON a) => a -> ByteString
toBase64JSON = Base64.encode . toStrict . JSON.encode

