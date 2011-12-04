{
module Parser (parse) where

import Scanner
}

%name parse
%tokentype { FrgToken }
%error { parseError }

%token 
      int             { TokInt $$ }
      float           { TokFloat $$ }
      '='             { TokSymbol "=" }
      '+'             { TokSymbol "+" }
      '-'             { TokSymbol "-" }
      '*'             { TokSymbol "*" }
      '/'             { TokSymbol "/" }
      ','             { TokComma }
      ';'             { TokSemicolon }
      ':'             { TokColon }
      '.'             { TokSymbol "." }
      'public'        { TokIdent "public" }
      'type'          { TokIdent "type" }
      'func'          { TokIdent "func" }
      'proc'          { TokIdent "proc" }
      'where'         { TokIdent "where" }
      'end'           { TokIdent "end" }
      ident           { TokIdent $$}
      '('             { TokLBracket Paren }
      ')'             { TokRBracket Paren }

%right in
%nonassoc '>' '<'
%left '+' '-'
%left '*' '/'
%left NEG
%%

Items : RevItems                { reverse $1 }

RevItems : {- empty -}          { [] }
         | RevItems Item        { $2:$1 }

Item  : Visibility 'type' TypeProto '=' Ctors
                                { TypeDecl $1 $3 $5 }
      | Visibility 'func' FnProto OptType '=' Exp
                                { FuncDecl $1 $3 $4 $6 }
      | Visibility 'proc' ProcProto ProcBody
                                { ProcDecl $1 $3 $4 }



TypeProto : ident OptIdents     { TypeProto $1 $2 }

Ctors : RevCtors                { reverse $1 }

RevCtors : FnProto              { [$1] }
       | RevCtors FnProto       { $2:$1 }

FnProto : ident OptParamList    { FnProto $1 $2 }

ProcProto : ident OptParamList  { ProcProto $1 $2 }

OptParamList : {- empty -}	{ [] }
       | '(' Params ')'         { $2 }

Params : RevParams              { reverse $1 }

RevParams : Param               { [$1] }
       | RevParams ',' Param    { $3 : $1 }

Param : ident OptType           { Param $1 $2 }

OptType : {- empty -}		{ Unspecified }
        | ':' Type              { $2 }


Type : ident OptTypeList        { Type $1 $2 }

OptTypeList : {- empty -}	{ [] }
       | '(' Types ')'          { $2 }

Types : RevTypes                { reverse $1 }

RevTypes : Type                 { [$1] }
      | RevTypes ',' Type       { $3 : $1 }


OptIdents : {- empty -}         { [] }
       | '(' Idents ')'         { $2 }

Idents : RevIdents              { reverse $1 }

RevIdents : ident               { [$1] }
       | RevIdents ',' ident    { $3:$1 }

Visibility : {- empty -}        { Private }
       | 'public'               { Public }

ProcBody : 'end'                { [] }
      | Stmt ProcBody           { $1:$2 }

Stmt  : ident '=' Exp           { Assign $1 $3 }

Exp   : Exp '+' Exp             { Plus $1 $3 }
      | Exp '-' Exp             { Minus $1 $3 }
      | Exp '*' Exp             { Times $1 $3 }
      | Exp '/' Exp             { Div $1 $3 }
      | '(' Exp ')'             { $2 }
      | '-' Exp %prec NEG       { Negate $2 }
      | int                     { IntValue $1 }
      | float                   { FloatValue $1 }
      | ident                   { Var $1 }



{
parseError :: [FrgToken] -> a
parseError _ = error "Parse error"

data Item
     = TypeDecl Visibility TypeProto [FnProto]
     | FuncDecl Visibility FnProto Type Exp
     | ProcDecl Visibility ProcProto ProcBody
    deriving Show

type Idents = [String]

data TypeProto = TypeProto String [String]
      deriving Show

data Type = Type String [Type]
          | Unspecified
      deriving Show

data FnProto = FnProto String [Param]
      deriving Show

data ProcProto = ProcProto String [Param]
      deriving Show

data Param = Param String Type
      deriving Show

type ProcBody = [Stmt]

data Stmt
     = Assign String Exp
    deriving Show

data Exp
      = Plus Exp Exp
      | Minus Exp Exp
      | Negate Exp
      | Times Exp Exp
      | Div Exp Exp
      | IntValue Integer
      | FloatValue Double
      | Var String 
      deriving Show

data Visibility = Public | Private deriving Show
}
