require 'spec_helper'

describe 'Code gen: array' do
  it "codegens array length" do
    run('a = [1, 2]; a.length').to_i.should eq(2)
  end

  it "codegens array get" do
    run('a = [1, 2]; a[0]').to_i.should eq(1)
  end

  it "codegens array set" do
    run('a = [1, 2]; a[1] = 3; a[1]').to_i.should eq(3)
  end

  it "codegens array set and get with union" do
    run('a = [0, 0]; a[0] = 1; a[1] = 1.5; a[0].to_i').to_i.should eq(1)
  end
end