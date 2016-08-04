module Grid exposing (Grid(..), insert, fromGraph, MatrixCell(..), toMatrix)

import Graph
import IntDict
import Matrix exposing (Matrix)

type Grid n e
  = Cell (Graph.NodeContext n e)
  | Serial (Grid n e) (Grid n e)
  | Parallel (List (Grid n e))
  | End

fromGraph : Graph.Graph n e -> Grid n e
fromGraph graph =
  List.foldl insert End <|
    List.concat (Graph.heightLevels graph)

type alias HeightFunc n e =
  Graph.NodeContext n e -> Int

type MatrixCell n e
  = MatrixNode (Graph.NodeContext n e)
  | MatrixSpacer
  | MatrixFilled

toMatrix : HeightFunc n e -> Grid n e -> Matrix (MatrixCell n e)
toMatrix nh grid =
  toMatrix' nh 0 0 (Matrix.matrix (height nh grid) (width grid) (always MatrixSpacer)) grid

toMatrix' : HeightFunc n e -> Int -> Int -> Matrix (MatrixCell n e) -> Grid n e -> Matrix (MatrixCell n e)
toMatrix' nh row col matrix grid =
  case grid of
    End ->
      matrix

    Serial a b ->
      toMatrix' nh row (col + width a) (toMatrix' nh row col matrix a) b
      -- toCells' w a ++ toCells' w b

    Parallel grids ->
      fst <| List.foldl (\g (m, row') -> (toMatrix' nh row' col m g, row' + height nh g)) (matrix, row) grids
      -- List.concatMap (toCells' w) grids

    Cell nc ->
      Matrix.set (row, col) (MatrixNode nc) (clearHeight row col (nh nc - 1) matrix)

clearHeight : Int -> Int -> Int -> Matrix (MatrixCell n e) -> Matrix (MatrixCell n e)
clearHeight row col height matrix =
  if height == 0 then
    matrix
  else
    clearHeight row col (height - 1) (Matrix.set (row + height, col) MatrixFilled matrix)

width : Grid n e -> Int
width grid =
  case grid of
    End ->
      0

    Serial a b ->
      width a + width b

    Parallel grids ->
      Maybe.withDefault 0 (List.maximum (List.map width grids))

    Cell _ ->
      1

height : HeightFunc n e -> Grid n e -> Int
height nh grid =
  case grid of
    End ->
      0

    Serial a b ->
      max (height nh a) (height nh b)

    Parallel grids ->
      List.sum (List.map (height nh) grids)

    Cell nc ->
      nh nc

insert : Graph.NodeContext n e -> Grid n e -> Grid n e
insert nc grid =
  case IntDict.size nc.incoming of
    0 ->
      addToStart (Cell nc) grid

    _ ->
      addAfterUpstreams nc grid

addToStart : Grid n e -> Grid n e -> Grid n e
addToStart a b =
  case b of
    End ->
      a

    Parallel bs ->
      case a of
        Parallel as' ->
          Parallel (bs ++ as')
        _ ->
          Parallel (bs ++ [a])

    _ ->
      case a of
        Parallel as' ->
          Parallel (b :: as')
        _ ->
          Parallel [b, a]

addAfterUpstreams : Graph.NodeContext n e -> Grid n e -> Grid n e
addAfterUpstreams nc grid =
  case grid of
    End ->
      End

    Parallel grids ->
      let
        (dependent, rest) =
          List.partition (leadsTo nc) grids
      in
        case dependent of
          [] ->
            grid

          [singlePath] ->
            Parallel (addAfterUpstreams nc singlePath :: rest)

          _ ->
            addToStart
              (Parallel rest)
              (addAfterMixedUpstreamsAndReinsertExclusiveOnes nc dependent)

    Serial a b ->
      if leadsTo nc a then
        Serial a (addToStart (Cell nc) b)
      else
        Serial a (addAfterUpstreams nc b)

    Cell upstreamOrUnrelated ->
      if IntDict.member nc.node.id upstreamOrUnrelated.outgoing then
        Serial grid (Cell nc)
      else
        grid

addAfterMixedUpstreamsAndReinsertExclusiveOnes : Graph.NodeContext n e -> List (Grid n e) -> Grid n e
addAfterMixedUpstreamsAndReinsertExclusiveOnes nc dependent =
  let
    (remainder, exclusives) =
      extractExclusiveUpstreams nc (Parallel dependent)
  in
    case (remainder, exclusives) of
      (Nothing, []) ->
        Debug.crash "impossible"

      (Nothing, _) ->
        Serial (Parallel (List.map Cell exclusives)) (Cell nc)

      (Just rem, []) ->
        Serial (Parallel dependent) (Cell nc)

      (Just rem, _) ->
        List.foldr
          addBeforeDownstream
          (addAfterUpstreams nc rem)
          exclusives

addBeforeDownstream : Graph.NodeContext n e -> Grid n e -> Grid n e
addBeforeDownstream nc grid =
  case grid of
    End ->
      End

    Parallel grids ->
      if comesDirectlyFrom nc grid then
        Serial (Cell nc) grid
      else
        Parallel (List.map (addBeforeDownstream nc) grids)

    Serial a b ->
      if comesDirectlyFrom nc b then
        Serial (addToStart (Cell nc) a) b
      else
        Serial a (addBeforeDownstream nc b)

    Cell upstreamOrUnrelated ->
      if comesDirectlyFrom nc grid then
        Debug.crash "too late to add in front of Cell"
      else
        grid

leadsTo : Graph.NodeContext n e -> Grid n e -> Bool
leadsTo nc grid =
  case grid of
    End ->
      False

    Parallel grids ->
      List.any (leadsTo nc) grids

    Serial a b ->
      leadsTo nc a || leadsTo nc b

    Cell upstreamOrUnrelated ->
      IntDict.member nc.node.id upstreamOrUnrelated.outgoing

comesDirectlyFrom : Graph.NodeContext n e -> Grid n e -> Bool
comesDirectlyFrom nc grid =
  case grid of
    End ->
      False

    Parallel grids ->
      List.any (comesDirectlyFrom nc) grids

    Serial a _ ->
      comesDirectlyFrom nc a

    Cell upstreamOrUnrelated ->
      IntDict.member nc.node.id upstreamOrUnrelated.incoming

extractExclusiveUpstreams : Graph.NodeContext n e -> Grid n e -> (Maybe (Grid n e), List (Graph.NodeContext n e))
extractExclusiveUpstreams target grid =
  case grid of
    End ->
      (Just grid, [])

    Parallel grids ->
      let
        recurse =
          List.map (extractExclusiveUpstreams target) grids

        remainders =
          List.map fst recurse

        exclusives =
          List.concatMap snd recurse
      in
        if List.all ((==) Nothing) remainders then
          (Nothing, exclusives)
        else
          (Just (Parallel <| List.filterMap identity remainders), exclusives)

    Serial a b ->
      -- in principle, if we can guarantee that this entire sequence ends
      -- with the target, this could return the 'Serial a b' itself
      (Just grid, [])

    Cell source ->
      if IntDict.size source.outgoing == 1 && IntDict.member target.node.id source.outgoing then
        (Nothing, [source])
      else
        (Just grid, [])