defmodule Gettext.PO do
  @moduledoc """
  This module provides facilities for working with `.po` files (mainly parsing).
  """

  alias Gettext.PO
  alias Gettext.PO.Tokenizer
  alias Gettext.PO.Parser
  alias Gettext.PO.SyntaxError
  alias Gettext.PO.Translation
  alias Gettext.PO.PluralTranslation

  @type line :: pos_integer
  @type parse_error :: {:error, line, binary}
  @type translation :: Translation.t | PluralTranslation.t

  defstruct headers: [], translations: [], file: nil

  @type t :: %__MODULE__{
    headers: [binary],
    translations: [translation],
    file: Path.t,
  }

  @doc """
  Parses a string into a list of translations.

  This function parses a given `str` into a list of `Gettext.PO.Translation` and
  `Gettext.PO.PluralTranslation` structs. It returns `{:ok, translations}` if
  there are no errors, otherwise `{:error, line, reason}`.

  ## Examples

      iex> {:ok, po} = Gettext.PO.parse_string \"""
      ...> msgid "foo"
      ...> msgstr "bar"
      ...> \"""
      iex> [t] = po.translations
      iex> t.msgid
      ["foo"]
      iex> t.msgstr
      ["bar"]
      iex> po.headers
      []

      iex> Gettext.PO.parse_string "foo"
      {:error, 1, "unknown keyword 'foo'"}

  """
  @spec parse_string(binary) :: {:ok, t} | parse_error
  def parse_string(str) do
    case Tokenizer.tokenize(str) do
      {:error, _line, _reason} = error ->
        error
      {:ok, tokens} ->
        case Parser.parse(tokens) do
          {:error, _line, _reason} = error ->
            error
          {:ok, headers, translations} ->
            {:ok, %PO{headers: headers, translations: translations}}
        end
    end
  end

  @doc """
  Parses a string into a list of translations, raising an exception if there are
  any errors.

  Works exactly like `parse_string/1`, but returns the list of translations
  if there are no errors or raises a `Gettext.PO.SyntaxError` error if there
  are.

  ## Examples

      iex> Gettext.PO.parse_string!("msgid")
      ** (Gettext.PO.SyntaxError) 1: no space after 'msgid'

  """
  @spec parse_string!(binary) :: t
  def parse_string!(str) do
    case parse_string(str) do
      {:ok, parsed} ->
        parsed
      {:error, line, reason} ->
        raise SyntaxError, line: line, reason: reason
    end
  end

  @doc """
  Parses the contents of a file into a list of translations.

  This function works similarly to `parse_string/1` except that it takes a file
  and parses the contents of that file. It can return:

    * `{:ok, translations}`
    * `{:error, line, reason}` if there is an error with the contents of the
      `.po` file (e.g., a syntax error)
    * `{:error, reason}` if there is an error with reading the file (this error
      is one of the errors that can be returned by `File.read/1`)_

  ## Examples

      Gettext.PO.parse_file "translations.po"
      #=> {:ok, [%Translation{msgid: "foo", msgstr: "bar"}]}

      Gettext.PO.parse_file "nonexistent"
      #=> {:error, :enoent}

  """
  @spec parse_file(Path.t) :: {:ok, t} | parse_error | {:error, atom}
  def parse_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        case parse_string(contents) do
          {:ok, po}                        -> {:ok, %{po | file: path}}
          {:error, _line, _reason} = error -> error
        end
      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Parses the contents of a file into a list of translations, raising if there
  are any errors.

  Works like `parse_file/1`, except that it raises a `Gettext.PO.SyntaxError`
  exception if there's a syntax error in the file or a `File.Error` error if
  there's an error with reading the file.

  ## Examples

      Gettext.PO.parse_file! "nonexistent.po"
      #=> ** (File.Error) could not parse file nonexistent.po: no such file or directory

  """
  @spec parse_file!(Path.t) :: t
  def parse_file!(path) do
    case parse_file(path) do
      {:ok, parsed} ->
        parsed
      {:error, reason} ->
        raise File.Error, reason: reason, action: "parse", path: path
      {:error, line, reason} ->
        raise SyntaxError, file: path, line: line, reason: reason
    end
  end

  @doc """
  Dumps a `Gettext.PO` struct as iodata.

  This function dumps a `Gettext.PO` struct (representing a PO file) as iodata,
  which can later be written to a file or converted to a string with
  `IO.iodata_to_binary/1`.

  ## Examples

  After running the following code:

      iodata = Gettext.PO.dump %Gettext.PO{
        headers: ["Last-Translator: Jane Doe"],
        translations: [
          %Gettext.PO.Translation{msgid: "foo", msgstr: "bar", comments: "# A comment"}
        ]
      }

      File.write!("/tmp/test.po", iodata)

  the `/tmp/test.po` file would look like this:

      msgid ""
      msgstr ""
      "Last-Translator: Jane Doe"

      # A comment
      msgid "foo"
      msgstr "bar"

  """
  @spec dump(t) :: iodata
  def dump(po)

  def dump(%PO{headers: [], translations: translations}) do
    dump_translations(translations)
  end

  def dump(%PO{headers: headers, translations: []}) do
    dump_headers(headers)
  end

  def dump(%PO{headers: headers, translations: translations}) do
    [dump_headers(headers), ?\n, dump_translations(translations)]
  end

  def dump_headers([]) do
    []
  end

  def dump_headers([first|_] = headers) when first != "" do
    dump_headers([""|headers])
  end

  def dump_headers(headers) do
    [
      ~s(msgid ""\n),
      dump_kw_and_strings("msgstr", headers, 0),
    ]
  end

  defp dump_translations(translations) do
    translations
    |> Enum.map(&dump_translation/1)
    |> Enum.intersperse(?\n)
  end

  defp dump_translation(%Translation{} = t) do
    [
      dump_comments(t.comments),
      dump_references(t.references),
      dump_kw_and_strings("msgid", t.msgid),
      dump_kw_and_strings("msgstr", t.msgstr),
    ]
  end

  defp dump_translation(%PluralTranslation{} = t) do
    [
      dump_comments(t.comments),
      dump_references(t.references),
      dump_kw_and_strings("msgid", t.msgid),
      dump_kw_and_strings("msgid_plural", t.msgid_plural),
      dump_plural_msgstr(t.msgstr)
    ]
  end

  defp dump_comments(comments) do
    # We dont' want to dump reference comments as they have to be taken care
    # of by the extractor.
    comments
    |> Enum.reject(&match?("#:" <> _, &1))
    |> Enum.map(&[&1, ?\n])
  end

  defp dump_references(references) do
    for {file, line} <- references do
      "#: #{file}:#{line}\n"
    end
  end

  defp dump_plural_msgstr(msgstr) do
    Enum.map msgstr, fn {plural_form, str} ->
      dump_kw_and_strings("msgstr[#{plural_form}]", str)
    end
  end

  defp dump_kw_and_strings(keyword, [first|rest], indentation \\ 2) do
    first = ~s(#{keyword} "#{escape(first)}"\n)
    rest  = Enum.map rest, &indent_line([?", escape(&1), ?", ?\n], indentation)
    [first, rest]
  end

  defp indent_line(str, indentation, with \\ " ") do
    [String.duplicate(with, indentation), str]
  end

  defp escape(str) do
    for <<char <- str>>, into: "", do: escape_char(char)
  end

  defp escape_char(?"),   do: ~S(\")
  defp escape_char(?\n),  do: ~S(\n)
  defp escape_char(?\t),  do: ~S(\t)
  defp escape_char(?\r),  do: ~S(\r)
  defp escape_char(char), do: <<char>>
end
