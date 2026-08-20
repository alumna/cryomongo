require "./spec_helper"

describe Mongo::Auth::Saslprep do
  it "returns printable ASCII unchanged and does not allocate a new string" do
    password = "pencil"
    Mongo::Auth::Saslprep.prepare(password).should be password
  end

  it "maps non-ASCII space to SPACE" do
    Mongo::Auth::Saslprep.prepare("a\u00A0b").should eq "a b"
  end

  it "maps commonly-mapped-to-nothing characters away" do
    Mongo::Auth::Saslprep.prepare("I\u00ADX").should eq "IX"
  end

  it "rejects ASCII control characters" do
    expect_raises(Mongo::Error, /prohibited/) do
      Mongo::Auth::Saslprep.prepare("a\nb")
    end
  end

  it "rejects a bidirectional mix of RandALCat and LCat" do
    # U+05D0 Hebrew Alef (RandALCat) next to Latin A (LCat)
    expect_raises(Mongo::Error, /bidirectional/) do
      Mongo::Auth::Saslprep.prepare("\u05D0A")
    end
  end

  it "keeps an all-RandALCat string" do
    Mongo::Auth::Saslprep.prepare("\u05D0\u05D1").should eq "\u05D0\u05D1"
  end
end
