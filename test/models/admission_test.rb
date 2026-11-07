require "test_helper"

class AdmissionTest < ActiveSupport::TestCase
  test "admits the emails on the list, whatever their case" do
    with_setting(:access, :emails, %w[ ajay@example.com smaya@example.com ]) do
      assert Admission.admits?("ajay@example.com")
      assert Admission.admits?("SMaya@Example.com")
    end
  end

  test "admits nobody else, and nobody at all by default" do
    with_setting(:access, :emails, %w[ ajay@example.com ]) do
      assert_not Admission.admits?("stranger@example.com")
      assert_not Admission.admits?("ajay@example.com.evil.test")
      assert_not Admission.admits?("")
      assert_not Admission.admits?(nil)
    end
    with_setting(:access, :emails, []) { assert_not Admission.admits?("ajay@example.com") }
  end

  test "an admin is admitted and on the admins list; nobody is one by default" do
    with_setting(:access, :emails, %w[ ajay@example.com smaya@example.com ]) do
      with_setting(:access, :admins, %w[ ajay@example.com stranger@example.com ]) do
        assert Admission.admin?("Ajay@Example.com")
        assert_not Admission.admin?("smaya@example.com")
        assert_not Admission.admin?("stranger@example.com"), "the admins list admits nobody by itself"
        assert_not Admission.admin?(nil)
      end
      with_setting(:access, :admins, []) { assert_not Admission.admin?("ajay@example.com") }
    end
  end
end
