// Shared by the unit and e2e tests: one person and one approved role.
import { job, newProfile, type Profile } from "@offerlane/core";

export const person = (): Profile => {
  const p = newProfile();
  Object.assign(p.personal, { first_name: "Ada", last_name: "Lovelace", full_name: "Ada Lovelace", email: "ada@example.com", phone: "+44 20 7946 0000", city: "London", country: "United Kingdom" });
  Object.assign(p.work, { current_company: "Engines Ltd", years_experience: "7", expected_salary: "£90,000" });
  p.authorization.authorized_countries = ["United Kingdom"];
  p.eeo.gender = "Decline to self-identify";
  return p;
};
export const FORM_URL = "http://127.0.0.1:4199/acme/jobs/101/apply";
export const role = () => ({ ...job({ id: "web:127.0.0.1:4199/acme/jobs/101", company: "Acme", title: "Platform Engineer", location: "London, UK",
  url: "http://127.0.0.1:4199/acme/jobs/101", apply_url: FORM_URL }), variant: "main" });
export const ANSWERS = "### Why do you want to work at Acme?\nBecause Acme builds the engines I care about.\n\n### Cover letter\nDear Acme, ...\n";
