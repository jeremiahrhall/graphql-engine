module Hasura.Backends.Postgres.DDL.Table
  ( updateColumnInEventTrigger
  , fetchAndValidateEnumValues
  )
where

import           Hasura.Prelude

import qualified Data.HashMap.Strict                 as Map
import qualified Data.List.NonEmpty                  as NE
import qualified Data.Sequence                       as Seq
import qualified Data.Sequence.NonEmpty              as NESeq
import qualified Database.PG.Query                   as Q
import qualified Language.GraphQL.Draft.Syntax       as G

import           Control.Monad.Trans.Control         (MonadBaseControl)
import           Control.Monad.Validate
import           Data.List                           (delete)
import           Data.Text.Extended

import           Hasura.Backends.Postgres.Connection
import           Hasura.Backends.Postgres.SQL.DML
import           Hasura.Backends.Postgres.SQL.Types
import           Hasura.Base.Error
import           Hasura.RQL.Types.Backend
import           Hasura.RQL.Types.Column
import           Hasura.RQL.Types.EventTrigger
import           Hasura.RQL.Types.Table
import           Hasura.SQL.Backend
import           Hasura.SQL.Types
import           Hasura.Server.Utils

updateColumnInEventTrigger
  :: QualifiedTable
  -> PGCol
  -> PGCol
  -> QualifiedTable
  -> EventTriggerConf ('Postgres pgKind) -> EventTriggerConf ('Postgres pgKind)
updateColumnInEventTrigger table oCol nCol refTable = rewriteEventTriggerConf
  where
    rewriteSubsCols = \case
      SubCStar       -> SubCStar
      SubCArray cols -> SubCArray $ map getNewCol cols
    rewriteOpSpec (SubscribeOpSpec listenColumns deliveryColumns) =
      SubscribeOpSpec
      (rewriteSubsCols listenColumns)
      (rewriteSubsCols <$> deliveryColumns)
    rewriteTrigOpsDef (TriggerOpsDef ins upd del man) =
      TriggerOpsDef
      (rewriteOpSpec <$> ins)
      (rewriteOpSpec <$> upd)
      (rewriteOpSpec <$> del)
      man
    rewriteEventTriggerConf etc =
      etc { etcDefinition =
            rewriteTrigOpsDef $ etcDefinition etc
          }
    getNewCol col =
      if table == refTable && oCol == col then nCol else col

data EnumTableIntegrityError (b :: BackendType)
  = EnumTablePostgresError !Text
  | EnumTableMissingPrimaryKey
  | EnumTableMultiColumnPrimaryKey ![PGCol]
  | EnumTableNonTextualPrimaryKey !(RawColumnInfo b)
  | EnumTableNoEnumValues
  | EnumTableInvalidEnumValueNames !(NE.NonEmpty Text)
  | EnumTableNonTextualCommentColumn !(RawColumnInfo b)
  | EnumTableTooManyColumns ![PGCol]

fetchAndValidateEnumValues
  :: forall pgKind m
   . (Backend ('Postgres pgKind), MonadIO m, MonadBaseControl IO m)
  => PGSourceConfig
  -> QualifiedTable
  -> Maybe (PrimaryKey ('Postgres pgKind) (RawColumnInfo ('Postgres pgKind)))
  -> [RawColumnInfo ('Postgres pgKind)]
  -> m (Either QErr EnumValues)
fetchAndValidateEnumValues pgSourceConfig tableName maybePrimaryKey columnInfos = runExceptT $
  either (throw400 ConstraintViolation . showErrors) pure =<< runValidateT fetchAndValidate
  where
    fetchAndValidate
      :: (MonadIO n, MonadBaseControl IO n, MonadValidate [EnumTableIntegrityError ('Postgres pgKind)] n)
      => n EnumValues
    fetchAndValidate = do
      maybePrimaryKeyColumn <- tolerate validatePrimaryKey
      maybeCommentColumn <- validateColumns maybePrimaryKeyColumn
      case maybePrimaryKeyColumn of
        Nothing               -> refute mempty
        Just primaryKeyColumn -> do
          result <- runPgSourceReadTx pgSourceConfig $ runValidateT $
                    fetchEnumValuesFromDb tableName primaryKeyColumn maybeCommentColumn
          case result of
            Left e             -> (refute . pure . EnumTablePostgresError . qeError) e
            Right (Left vErrs) -> refute vErrs
            Right (Right r)    -> pure r
      where
        validatePrimaryKey = case maybePrimaryKey of
          Nothing -> refute [EnumTableMissingPrimaryKey]
          Just primaryKey -> case _pkColumns primaryKey of
            column NESeq.:<|| Seq.Empty -> case prciType column of
              PGText -> pure column
              _      -> refute [EnumTableNonTextualPrimaryKey column]
            columns -> refute [EnumTableMultiColumnPrimaryKey $ map prciName (toList columns)]

        validateColumns primaryKeyColumn = do
          let nonPrimaryKeyColumns = maybe columnInfos (`delete` columnInfos) primaryKeyColumn
          case nonPrimaryKeyColumns of
            [] -> pure Nothing
            [column] -> case prciType column of
              PGText -> pure $ Just column
              _      -> dispute [EnumTableNonTextualCommentColumn column] $> Nothing
            columns -> dispute [EnumTableTooManyColumns $ map prciName columns] $> Nothing

    showErrors :: [EnumTableIntegrityError ('Postgres pgKind)] -> Text
    showErrors allErrors =
      "the table " <> tableName <<> " cannot be used as an enum " <> reasonsMessage
      where
        reasonsMessage = makeReasonMessage allErrors showOne

        showOne :: EnumTableIntegrityError ('Postgres pgKind) -> Text
        showOne = \case
          EnumTablePostgresError err -> "postgres error: " <> err
          EnumTableMissingPrimaryKey -> "the table must have a primary key"
          EnumTableMultiColumnPrimaryKey cols ->
            "the table’s primary key must not span multiple columns ("
              <> commaSeparated (sort cols) <> ")"
          EnumTableNonTextualPrimaryKey colInfo -> typeMismatch "primary key" colInfo PGText
          EnumTableNoEnumValues -> "the table must have at least one row"
          EnumTableInvalidEnumValueNames values ->
            let pluralString = " are not valid GraphQL enum value names"
                valuesString = case NE.reverse (NE.sort values) of
                  value NE.:| [] -> "value " <> value <<> " is not a valid GraphQL enum value name"
                  value2 NE.:| [value1] -> "values " <> value1 <<> " and " <> value2 <<> pluralString
                  lastValue NE.:| otherValues ->
                    "values " <> commaSeparated (reverse otherValues) <> ", and "
                      <> lastValue <<> pluralString
            in "the " <> valuesString
          EnumTableNonTextualCommentColumn colInfo -> typeMismatch "comment column" colInfo PGText
          EnumTableTooManyColumns cols ->
            "the table must have exactly one primary key and optionally one comment column, not "
              <> tshow (length cols) <> " columns ("
              <> commaSeparated (sort cols) <> ")"
          where
            typeMismatch description colInfo expected =
              "the table’s " <> description <> " (" <> prciName colInfo <<> ") must have type "
                <> expected <<> ", not type " <>> prciType colInfo

fetchEnumValuesFromDb
  :: forall pgKind m
   . (MonadTx m, MonadValidate [EnumTableIntegrityError ('Postgres pgKind)] m)
  => QualifiedTable
  -> RawColumnInfo ('Postgres pgKind)
  -> Maybe (RawColumnInfo ('Postgres pgKind))
  -> m EnumValues
fetchEnumValuesFromDb tableName primaryKeyColumn maybeCommentColumn = do
  let nullExtr = Extractor SENull Nothing
      commentExtr = maybe nullExtr (mkExtr . prciName) maybeCommentColumn
      query = Q.fromBuilder $ toSQL mkSelect
        { selFrom = Just $ mkSimpleFromExp tableName
        , selExtr = [mkExtr (prciName primaryKeyColumn), commentExtr] }
  rawEnumValues <- liftTx $ Q.withQE defaultTxErrorHandler query () True
  when (null rawEnumValues) $ dispute [EnumTableNoEnumValues]
  let enumValues = flip map rawEnumValues $
        \(enumValueText, comment) ->
          case mkValidEnumValueName enumValueText of
            Nothing        -> Left enumValueText
            Just enumValue -> Right (EnumValue enumValue, EnumValueInfo comment)
      badNames = lefts enumValues
      validEnums = rights enumValues
  case NE.nonEmpty badNames of
    Just someBadNames -> refute [EnumTableInvalidEnumValueNames someBadNames]
    Nothing           -> pure $ Map.fromList validEnums
  where
    -- https://graphql.github.io/graphql-spec/June2018/#EnumValue
    mkValidEnumValueName name =
      if name `elem` ["true", "false", "null"] then Nothing
      else G.mkName name
