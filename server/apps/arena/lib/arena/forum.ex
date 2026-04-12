defmodule Arena.Forum do
  @moduledoc """
  GenServer for forum state. Stores messages per forum_id.
  Max 35 messages per forum. Persists to priv/foros/ using :erlang.term_to_binary.
  """

  use GenServer

  @max_messages 35

  # ---- Public API ----

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Get messages for a forum. Returns list of %{author, title, body}."
  def get_messages(forum_id) do
    GenServer.call(__MODULE__, {:get_messages, forum_id})
  end

  @doc "Post a message to a forum."
  def post_message(forum_id, author, title, body) do
    GenServer.cast(__MODULE__, {:post_message, forum_id, author, title, body})
  end

  # ---- GenServer callbacks ----

  @impl true
  def init(_opts) do
    forums = load_all_forums()
    {:ok, %{forums: forums}}
  end

  @impl true
  def handle_call({:get_messages, forum_id}, _from, state) do
    messages = Map.get(state.forums, forum_id, [])
    {:reply, messages, state}
  end

  @impl true
  def handle_cast({:post_message, forum_id, author, title, body}, state) do
    messages = Map.get(state.forums, forum_id, [])
    new_msg = %{author: author, title: title, body: body}
    messages = Enum.take([new_msg | messages], @max_messages)
    forums = Map.put(state.forums, forum_id, messages)
    persist_forum(forum_id, messages)
    {:noreply, %{state | forums: forums}}
  end

  # ---- Persistence ----

  defp forum_dir do
    Path.join(:code.priv_dir(:arena), "foros")
  end

  defp forum_path(forum_id) do
    Path.join(forum_dir(), "forum_#{forum_id}.dat")
  end

  defp load_all_forums do
    dir = forum_dir()

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.reduce(%{}, fn filename, acc ->
        case Regex.run(~r/^forum_(\d+)\.dat$/, filename) do
          [_, id_str] ->
            forum_id = String.to_integer(id_str)
            path = Path.join(dir, filename)

            case File.read(path) do
              {:ok, bin} ->
                try do
                  messages = :erlang.binary_to_term(bin)
                  Map.put(acc, forum_id, messages)
                rescue
                  _ -> acc
                end

              _ ->
                acc
            end

          _ ->
            acc
        end
      end)
    else
      %{}
    end
  end

  defp persist_forum(forum_id, messages) do
    dir = forum_dir()
    File.mkdir_p!(dir)
    File.write!(forum_path(forum_id), :erlang.term_to_binary(messages))
  end
end
