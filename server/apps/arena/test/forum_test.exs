defmodule Arena.ForumTest do
  @moduledoc """
  Tests for the forum GenServer (Arena.Forum) — task 44.

  Covers:
  - Starting the forum GenServer
  - Posting and retrieving messages
  - Max 35 messages per forum (LIFO, newest first)
  - Multiple forums are independent
  - Empty forum returns empty list
  - Messages have author, title, body fields
  - ItemDef forum_id field
  """
  use ExUnit.Case, async: false

  alias Arena.Forum

  # Use high forum IDs to avoid collisions with persisted data
  @base_forum_id 90_000

  setup do
    # Start a fresh Forum GenServer for each test
    {:ok, pid} = Forum.start_link(name: nil)
    # Generate unique forum IDs per test run using a counter
    forum_id = @base_forum_id + :erlang.unique_integer([:positive])
    %{forum: pid, forum_id: forum_id}
  end

  describe "get_messages" do
    test "empty forum returns empty list", %{forum: pid, forum_id: fid} do
      messages = GenServer.call(pid, {:get_messages, fid})
      assert messages == []
    end
  end

  describe "post_message" do
    test "posting a message makes it retrievable", %{forum: pid, forum_id: fid} do
      GenServer.cast(pid, {:post_message, fid, "Gandalf", "Hola", "Bienvenidos al foro."})
      # Give the cast time to process
      :timer.sleep(10)

      messages = GenServer.call(pid, {:get_messages, fid})
      assert length(messages) == 1
      assert hd(messages).author == "Gandalf"
      assert hd(messages).title == "Hola"
      assert hd(messages).body == "Bienvenidos al foro."

      cleanup_forum_file(fid)
    end

    test "messages are in LIFO order (newest first)", %{forum: pid, forum_id: fid} do
      GenServer.cast(pid, {:post_message, fid, "A", "First", "Body1"})
      GenServer.cast(pid, {:post_message, fid, "B", "Second", "Body2"})
      GenServer.cast(pid, {:post_message, fid, "C", "Third", "Body3"})
      :timer.sleep(20)

      messages = GenServer.call(pid, {:get_messages, fid})
      assert length(messages) == 3
      assert Enum.at(messages, 0).author == "C"
      assert Enum.at(messages, 1).author == "B"
      assert Enum.at(messages, 2).author == "A"

      cleanup_forum_file(fid)
    end

    test "max 35 messages per forum", %{forum: pid, forum_id: fid} do
      for i <- 1..40 do
        GenServer.cast(pid, {:post_message, fid, "User#{i}", "Title#{i}", "Body#{i}"})
      end

      :timer.sleep(50)

      messages = GenServer.call(pid, {:get_messages, fid})
      assert length(messages) == 35
      # Newest message (40) should be first
      assert hd(messages).author == "User40"

      cleanup_forum_file(fid)
    end

    test "different forums are independent", %{forum: pid, forum_id: fid} do
      fid2 = fid + 1
      GenServer.cast(pid, {:post_message, fid, "Alice", "Forum1", "Body1"})
      GenServer.cast(pid, {:post_message, fid2, "Bob", "Forum2", "Body2"})
      :timer.sleep(20)

      messages1 = GenServer.call(pid, {:get_messages, fid})
      messages2 = GenServer.call(pid, {:get_messages, fid2})

      assert length(messages1) == 1
      assert length(messages2) == 1
      assert hd(messages1).author == "Alice"
      assert hd(messages2).author == "Bob"

      cleanup_forum_file(fid)
      cleanup_forum_file(fid2)
    end
  end

  # ---- ItemDef forum_id field ----

  describe "ItemDef forum_id field" do
    test "ItemDef has forum_id field defaulting to 0" do
      item_def = %Arena.Data.ItemDef{}
      assert item_def.forum_id == 0
    end
  end

  # Clean up persisted forum files created during tests
  defp cleanup_forum_file(forum_id) do
    path = Path.join([:code.priv_dir(:arena), "foros", "forum_#{forum_id}.dat"])
    File.rm(path)
  end
end
