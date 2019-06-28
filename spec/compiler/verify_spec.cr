describe Mare::Compiler::Completeness do
  it "complains when a constructor has an error-able body" do
    source = Mare::Source.new_example <<-SOURCE
    :actor Main
      :new
        error!
    SOURCE
    
    expected = <<-MSG
    This constructor may raise an error, but that is not allowed:
    from (example):2:
      :new
       ^~~
    MSG
    
    expect_raises Mare::Error, expected do
      Mare::Compiler.compile([source], :verify)
    end
  end
  
  it "complains when a no-exclamation function has an error-able body" do
    source = Mare::Source.new_example <<-SOURCE
    :actor Main
      :new
    
    :primitive Example
      :fun risky (x U64)
        if (x == 0) (error!)
    SOURCE
    
    expected = <<-MSG
    This function name needs an exclamation point because it may raise an error:
    from (example):5:
      :fun risky (x U64)
           ^~~~~
    
    - it should be named 'risky!' instead:
      from (example):5:
      :fun risky (x U64)
           ^~~~~
    MSG
    
    expect_raises Mare::Error, expected do
      Mare::Compiler.compile([source], :verify)
    end
  end
end